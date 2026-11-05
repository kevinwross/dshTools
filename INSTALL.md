# Installing DSH Tools on a new machine

This repository is a bundle of machine-local tools for DeepSeek Harness, not an
application. Nothing here is built; everything is installed by one script.

```
DSH Tools/
├── install.ps1              # the installer
├── skills/
│   └── grab-window/         # shared skill: SKILL.md + grab-window.ps1
└── local-datetime/          # DSH plugin package (@local/dsh-tool-local-datetime)
```

## Prerequisites

| Need | Why | Check |
|---|---|---|
| Windows 10/11 | Win32/GDI capture, junctions, `.cmd` shims | `$env:OS` |
| PowerShell 7 | runs the installer and the tools | `$PSVersionTable.PSVersion` |
| DeepSeek Harness | what these tools extend | `dsh --version`, or a source checkout |
| node + pnpm | `dsh plugin` forwards to pnpm | `node -v`, `pnpm -v` |

## Install

```powershell
git clone <your-remote> "C:\Users\<you>\source\repos\DSH Tools"
cd "C:\Users\<you>\source\repos\DSH Tools"
pwsh -NoProfile -File .\install.ps1 -DryRun    # see the plan
pwsh -NoProfile -File .\install.ps1            # apply it
```

Re-running is safe. It makes whatever is missing and reports the rest as `skip`, so it
doubles as a repair command after moving the repository.

## What it does

| Step | Effect |
|---|---|
| Shared skill root | junctions `%USERPROFILE%\.agents\skills` to this repo's `skills\`. DSH scans that root at rank 500, so every project on the machine discovers these skills with no per-project setup. |
| PATH shims | for each `skills\<name>\<name>.ps1`, writes `%USERPROFILE%\.local\bin\<name>.cmd`, so harnesses that never read a skill catalog can still run the tool. |
| Plugins | `dsh plugin --profile <profile> add <dir>` for every package whose `package.json` declares `dsh.bundle`. dsh records both the `link:` dependency and the profile's `bundles` entry, which is the part that is easy to get wrong by hand. |

After it runs, a new DSH session should list `grab-window` among its skills, and
`grab-window -List` should work from any directory.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `-Profile <name>` | `web` | profile that receives the plugins |
| `-DshCommand <cmd>` | auto | how to invoke dsh. Auto tries `dsh` on PATH, then `$env:DSH_CLI`, then a checkout at `$env:DSH_CHECKOUT` or `C:\AI\deepseek-harness` |
| `-DryRun` | off | print the plan and change nothing |

## Manual equivalent

If you would rather not run a script, the three steps are short:

```powershell
# 1. shared skill root
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents" | Out-Null
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills" `
         -Target "C:\path\to\DSH Tools\skills"

# 2. one shim per skills\<name>\<name>.ps1 - write <name>.cmd as:
#    @echo off
#    setlocal
#    pwsh -NoProfile -File "C:\path\to\DSH Tools\skills\grab-window\grab-window.ps1" %*

# 3. the plugin
dsh plugin --profile web add "C:\path\to\DSH Tools\local-datetime"
```

## Uninstall

```powershell
dsh plugin --profile web remove @local/dsh-tool-local-datetime
Remove-Item "$env:USERPROFILE\.local\bin\grab-window.cmd"
Remove-Item "$env:USERPROFILE\.agents\skills"    # removes the junction, not the target
```

## Troubleshooting

- **`dsh` not found** — the plugin step is skipped and the exact command is printed. Pass
  `-DshCommand 'C:\path\to\dsh.exe'`, set `DSH_CLI`, or set `DSH_CHECKOUT` to a source
  checkout.
- **`grab-window` is not recognized** — `%USERPROFILE%\.local\bin` is not on PATH. Add it
  to the *user* PATH and open a new terminal; the installer warns when this is the case.
- **`~/.agents/skills` already exists as a real folder** — the installer refuses to touch
  it rather than deleting data. Move its contents into this repo's `skills\`, delete the
  folder, re-run.
- **Execution policy blocks the script** — `pwsh -ExecutionPolicy Bypass -File .\install.ps1`.
- **The repository moved** — re-run the installer; the junction and shims store absolute
  paths, so they cannot follow it.
- **Every shell command fails with `no sandbox backend is usable on this host`** — a
  Linux/DSH host problem, not an installer one; see
  [FixBashSandboxOnLinux.md](FixBashSandboxOnLinux.md).

## Notes

- This repository is already initialised: `.git`, the `origin` remote, and a `.gitignore`
  that excludes `*.png` and `captures/` — grab-window's default output — so clones stay
  small. Keep capture PNGs out of the history by writing them where that ignores them.
- The installer deliberately does not touch Ollama models, provider settings, or
  `cordis.patch.yml`. Those are machine-specific and documented separately in
  [MakeOrnithWorkWithDSH.md](MakeOrnithWorkWithDSH.md).
