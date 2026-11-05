# Fixing "no sandbox backend is usable on this host" (Linux)

Notes from diagnosing, on 2026-11-05 at 10:46 PDT, why every `bash` call in a DSH
session failed with:

```
sandbox mode "workspace-write" is requested but no sandbox backend is usable on
this host; refusing to run the command unconfined. …
```

Host: Ubuntu 24.04 kernel (`Linux 7.0.0-42-generic`), user `kevinro`, DSH run from the
source checkout at `/home/kevinro/ai/deepseek-harness`. This is a **Linux** problem;
the Windows installer in [INSTALL.md](INSTALL.md) does not apply.

**Status: resolved 2026-11-05 10:58 PST.** Both rungs work. bwrap is now the active
backend (pid isolation, private `/dev`, `/proc` and `/tmp`), with Landlock as the
fallback. `workspace-write` bash runs with no escalation, and confinement was verified at
the boundary — see [verification](#restart-done-and-verified) and
[which rung is active](#which-rung-is-active).

## Short version

Two independent faults, one per rung of the Linux runner chain. The provider fails
closed because *both* failed:

| Rung | Fault | Fix |
|---|---|---|
| `bwrap` (preferred) | Installed, but the unprivileged-userns restriction transitioned it into a profile that denies the mapping it needs → `bwrap: setting up uid map: Permission denied` | **Done** — scoped AppArmor profile with `userns,` (needs root once). See [Fault 1](#fault-1--bwrap-and-the-userns-restriction-fixed) |
| `landlock` (fallback) | Kernel supports it, but the prebuilt launcher `bin/landlock-run` was **missing** from the checkout | **Done** — dropped in the published prebuilt |

Either rung alone is enough; the provider fails closed only when *both* fail.

Both rungs now pass their probes, and after the 2026-11-05 10:58 start the host selected
the preferred `bwrap` rung. See [which rung is active](#which-rung-is-active).

## How the chain decides

`packages/sandbox/sandbox-local/src/index.ts`:

- `PLATFORM_CHAINS.linux = ['bwrap', 'landlock']` (line ~161) — probed in preference
  order, first passing rung wins.
- The bwrap probe (line ~70) spawns `bwrap <read-only profile> -- true` and requires
  exit 0. Profile args come from `bwrapProfileArgs()` in `src/profiles.ts`: `--ro-bind
  / / --dev /dev --unshare-pid --proc /proc --die-with-parent`. Note it does **not**
  unshare the network — testing with `--unshare-all` gives a misleading
  `loopback: Failed RTM_NEWADDR` error instead.
- The landlock probe calls `probe(launcherPath())`, which runs `landlock-run --probe`
  and requires exit 0; a `partially enforced` report maps to `partial`, anything else
  non-zero maps to `unusable`.

**Critical detail:** the verdict is cached for the lifetime of the provider —

```ts
private selectRunner(mode: ConfinedSandboxMode): SelectedRunner {
  this.selectedRunner ??= this.chainVerdict()
  if (this.selectedRunner === 'unavailable') throw new SandboxUnavailableError(mode)
```

`'unavailable'` is cached like any other value and never re-probed. **Repairing the
host does not help a running host; it must be restarted.**

## Fault 1 — bwrap and the userns restriction (FIXED)

`bubblewrap 0.9.0-1ubuntu0.3` is installed at `/usr/bin/bwrap`, but:

```console
$ bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true
bwrap: setting up uid map: Permission denied
```

The relevant setting is `/proc/sys/kernel/apparmor_restrict_unprivileged_userns = 1`
(Ubuntu 24.04's default hardening; note it is **not** the older Debian
`unprivileged_userns_clone` knob, which is also `1` here and irrelevant).

**Corrected mechanism** — an earlier version of this note claimed the kernel denies
userns creation outright. The audit log disproved that. Creation is *allowed*, and the
task is transitioned into a restricted profile, which then denies exactly what bwrap
needs to finish the job:

```console
apparmor="AUDIT" operation="userns_create" profile="unconfined" comm="bwrap"
         requested="userns_create" target="unprivileged_userns" execpath="/usr/bin/bwrap"
apparmor="DENIED" operation="capable" class="cap" profile="unprivileged_userns"
         comm="bwrap" capability=8 capname="setpcap"
apparmor="DENIED" operation="open" class="file" profile="unprivileged_userns"
         name="proc/3371/uid_map" requested_mask="wr" denied_mask="wr"
```

`/etc/apparmor.d/unprivileged_userns` is that transition target: it has `allow userns`
but `audit deny capability`, and its file rules cannot match the "disconnected path" of
`/proc/<pid>/uid_map`. The net effect is a user namespace that can be created but never
mapped — which is the same wall bwrap hits as `setting up uid map: Permission denied`.

**Fix applied** — give only `/usr/bin/bwrap` the `userns,` permission, in the shape
Ubuntu already ships for `/usr/bin/lxc-usernsexec`: a named profile with
`flags=(unconfined)` whose only rule is `userns,`. Attaching a profile of its own means
bwrap is no longer the unconfined task that gets force-transitioned, so the restrictive
target never applies; `flags=(unconfined)` keeps every other check permissive, leaving
bwrap's own sandboxing untouched. Needs root once (password required; user is in `sudo`):

```bash
sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF
sudo apparmor_parser -r /etc/apparmor.d/bwrap
```

Confirmed loaded by the kernel audit log:

```console
apparmor="STATUS" operation="profile_load" profile="unconfined" name="bwrap" pid=3919 comm="apparmor_parser"
```

After that, bwrap no longer emits `userns_create` transition records at all, and the
probe passes (see [verification](#bwrap-verified)). The profile persists across reboots
because the AppArmor service loads `/etc/apparmor.d/*` at boot.

Alternative, if the scoped profile ever stops being enough: loosen the global knob
instead. This restores pre-24.04 behaviour machine-wide and re-opens unprivileged
user namespaces for **every** process — a wider privilege-escalation surface, so it is
the fallback, not the preference.

```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-userns.conf
```

## Fault 2 — missing landlock launcher (FIXED)

Landlock is active in the kernel (`/sys/kernel/security/lsm` =
`lockdown,capability,landlock,yama,apparmor,bpf,ima,evm`), so this rung should have
worked. It failed because the binary did not exist:

```console
launcherPath: …/native/system/packages/linux-x64/bin/landlock-run
→ No such file or directory     (probe verdict: "unusable")
```

The checkout's platform package shipped only `bin/glibc/system.node`, even though
`native/system/packages/linux-x64/prebuilds.json` declares `bin/landlock-run` and
`bin/musl/system.node`. The native prebuilts were never fully populated.

**Fix applied** — installed the published prebuilt:

```bash
cd /tmp && npm pack @deepseek-ai/node-addon-system-linux-x64@0.1.2 && tar -xzf *.tgz
cp -p package/bin/landlock-run \
  /home/kevinro/ai/deepseek-harness/native/system/packages/linux-x64/bin/
chmod 755 /home/kevinro/ai/deepseek-harness/native/system/packages/linux-x64/bin/landlock-run
```

Installed: 38552 bytes, mode 755,
sha256 `a752bc72f111fcc573c3e61fb90fa544541dac0ca498d2e279e1630d7c659b31`.

### Verified, not assumed

| Check | Result |
|---|---|
| `landlock-run --probe` | `landlock: fully enforced`, exit 0 |
| Library `probe(launcherPath())` — the provider's own path | `"full"` |
| Write inside a granted root (`/tmp`) | succeeded |
| Write outside all grants (`/home/kevinro/ll_denied.txt`) | `Permission denied` |

The last row matters: it proves enforcement is real, not merely that a probe printed
a happy line.

## Restart, done and verified

The host was `pnpm dsh web` (PID 3914 → 3923 → node 3937 on `127.0.0.1:3080`), started
manually from a terminal, with no systemd unit. It had cached `'unavailable'` at
startup, so it was restarted:

```bash
# in the terminal that owns it: Ctrl-C, then
cd /home/kevinro/ai/deepseek-harness && pnpm dsh web
```

A fresh provider then walked the chain: `bwrap` probed → fails → `landlock` probed →
`full` → `workspace-write` selected. Verified afterwards from a **normal, unescalated**
`bash` call (no `sandbox_permissions`):

| Check | Expected | Result |
|---|---|---|
| `landlock-run --probe` | `fully enforced`, exit 0 | ✅ |
| Write inside the session workspace | allowed | ✅ |
| Write to `/home/kevinro/_outside_probe.txt` | `Permission denied` | ✅ |
| Write to `/tmp` (granted temp area) | allowed | ✅ |
| Read outside the workspace | allowed (read-only `/` grant) | ✅ |
| `bwrap … -- true` from that shell | `uid map: Permission denied` — **expected**, see [the gotcha](#gotcha-bwrap-cannot-be-tested-from-inside-a-dsh-sandbox) | ⚠️ not a fault |

The bwrap row is a trap, not a failure: the `bash` tool's own Landlock confinement blocks
what bwrap needs. bwrap was verified separately, unconfined —
see [bwrap verified](#bwrap-verified). Repeat this table if the problem ever returns.

## bwrap verified

Validated with the profile loaded, from an **unconfined** process:

```console
$ bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent \
    -- sh -c 'echo INNER OK; cat /proc/self/attr/current'
INNER OK
bwrap (unconfined)
exit: 0

$ bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true
probe exit: 0
```

`bwrap (unconfined)` is the payoff line: the process really is running under the `bwrap`
profile, which is what permits the user namespace.

### Gotcha: bwrap cannot be tested from inside a DSH sandbox

This burned an hour and produced a wrong diagnosis, so it is worth stating plainly.
Testing bwrap from a `workspace-write` `bash` call fails with the *same*
`setting up uid map: Permission denied` message, even with the AppArmor fix in place —
because the shell is already inside Landlock, and **Landlock denies the write to
`/proc/self/uid_map`** that bwrap needs. The error looks identical; the cause is
different and the audit log shows no AppArmor denial at all.

Rule of thumb: test sandbox backends from a plain terminal, or at least unconfined.
Layer-on-layer tells you nothing about the inner layer. This does not affect normal
operation — DSH spawns bwrap from the unconfined host, not from inside a sandbox.

## Which rung is active

`PLATFORM_CHAINS.linux = ['bwrap', 'landlock']` is probed in order, so once bwrap's
profile was loaded the next host start selected it automatically.

**bwrap is active as of the 2026-11-05 10:58 PST start.** Confirmed from inside a plain
`workspace-write` `bash` call — the process tree gives it away:

```console
pid of me:      2
pid 1 comm:     bwrap
pid 1 cmdline:  bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc
                --die-with-parent --tmpfs /tmp --bind <workspace> <workspace> -- bash …
visible procs:  6            # the host has far more
/dev entries:   14           # bwrap's minimal devtmpfs, not the host's /dev
/tmp contents:  0            # host /tmp hidden behind an empty tmpfs
```

The denial dialect is the clincher. bwrap denies writes with **EROFS** (read-only bind);
Landlock denies with **EACCES**:

```console
$ echo x > /home/kevinro/_probe3.txt
bash: /home/kevinro/_probe3.txt: Read-only file system
```

That matches bwrap's `denialSignatures` (`['read-only file system']`) in
`sandbox-local/src/index.ts`, so a rejected write here is provably a bwrap denial and not
a stray Landlock one. Verified in this mode: workspace writable, `/tmp` writable but
empty, reads outside allowed, writes outside denied.

| | bwrap (active) | Landlock (fallback) |
|---|---|---|
| Mechanism | mount namespace + `--ro-bind / /` | path-based kernel allow-list |
| PID isolation | yes (`--unshare-pid`) | no |
| `/proc` | remounted inside the namespace | host's `/proc` |
| `/tmp` | `--tmpfs /tmp`, empty | real `/tmp`, granted rw |

Both report `full` enforcement in the provider. If bwrap ever causes trouble, deleting
`/etc/apparmor.d/bwrap` and restarting returns the host to Landlock with no other change.

## Caveats worth remembering

- **The binary is an untracked artifact** inside the harness checkout. A future
  `pnpm install` or native rebuild could remove it; re-apply with the `npm pack` recipe
  above. `bin/musl/system.node` is still missing, which is harmless on glibc Node but
  would matter under a musl runtime.
- **Under bwrap, `/tmp` does not survive between commands.** Each `bash` call is a fresh
  `bwrap` invocation with its own `--tmpfs /tmp`, so a file written to `/tmp` in one call
  is gone in the next. Verified: write `/tmp/_persist_probe.txt` in one call, the next
  call reports `No such file or directory`. This is a genuine regression from Landlock,
  where `/tmp` was the host's real directory. Use the session workspace for scratch that
  needs to persist across calls; only the workspace and `/tmp` are writable, and only the
  workspace is shared.
- **Escalation is a workaround, not a fix.** `sandbox_permissions: danger-full-access`
  on a `bash` call runs the command **unconfined**. Use it to bootstrap a repair like
  this one, or to test a backend that cannot run inside another backend, but not as the
  steady state.
- Nothing here depends on a reboot specifically — a host restart is what matters. The
  installed binary lives on disk and survives reboots; after a machine reboot just
  relaunch `pnpm dsh web`.
- Scratch files from this session (`/tmp/tmp.Ttt7rAWIq9`, the extracted tarball) are
  cleared on reboot and are not needed.
