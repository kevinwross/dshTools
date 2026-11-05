# MakeOrnithWorkWithDSH

Portable notes for repaying the Ollama/config fixes you ran on *this* machine to the deepseek-harness (DSH) profile patch files on other machines that want a long-context local model (`ornith-dsh`) to actually work.

Copy, re-find your profile path, and edit the model entry. These edits are plain and reversible, and the same file structure applies on every DSH checkout.

---

## 1. Understand the three numbers (so you know which to change)

Three layers count on *this same quantity* in DSH:

| Layer | Field / knob | What it does |
|---|---|---|
| Model itself | Ollama `num_ctx` | Real context budget. Set in the Modelfile via `PARAMETER num_ctx 128000`. **DSH cannot read or inherit this value** — `/v1/models` only reports `{id, object, created, owned_by}`. It comes from the model at draw time, nothing else. |
| DSH profile patch | `contextWindow` on the `ornith` model entry in `cordis.patch.yml` | Window DSH tells Ollama you expect. **Must match the built-in `num_ctx`.** |
| Request/output cap | `maxTokens` on the same entry | Capped tokens per request; also becomes this model's **per-request default**. The config always wins over the Modelfile `num_predict` default in either direction (see §4). |

Also on each machine: run

```powershell
$DSH_HOME=env | Select-String -Pattern '^DSH' | ForEach-Object { $_.Line }   # confirm env vars
ollama ps                                                              # what is loaded, and num_ctx/num_predict columns
ollama show ornith-dsh:latest --parameters                             # the exact num_ctx / num_predict to copy (edit if present)
```

That gives you `num_ctx 128000` / `num_predict 16384` plus `repeat_penalty`, `temperature`, `top_p`. Note all four, but only `_ctx` and `_predict` matter here.

**Rule of thumb:**
- `contextWindow` = the built-in `num_ctx`, exactly.
- `maxTokens` = a cap for your requests, kept **below** `num_predict` (16384) so the cap applies rather than being ignored. 4096 is the practical value.
- Compaction starts at ~0.8× window (~102k tokens), so leave comfortable room between `maxTokens` and `contextWindow`.

---

## 2. Find the profile patch file (findable, not hardcoded)

```powershell
echo $env:DSH_HOME        # e.g. C:\Users\<name>\.dsh
echo $env:DSH_PROFILE     # e.g. web
Get-ChildItem "$env:DSH_HOME\profiles" -Directory | Select-Object -ExpandProperty Name   # your profile name
```

Then open for editing … note the actual extension can differ between machines — **this host is `.yml`, others may be `.yaml`**, so open whatever suffix your file listing shows:

```powershell
Get-ChildItem "$env:DSH_HOME\profiles\<<profile>>" | Where-Object { $_.Name -match '(^|\\)cordis(\.yml|\.yaml)?$' }   # list the patch file
```

It's a **top-level YAML array** of loader patches (id → name → `config`). `patchReload: live` (profile `package.json`) makes it reload on save, so after a clean editor write you can usually skip the restart.

Locate the entry whose `model.id == ornith-dsh:<tag>` — change `<tag>` to *your* tag (`ornith-dsh:latest`, `ornith-1.5:9b`, etc.). It currently looks like this:

```yaml
          - id: ornith-dsh:latest
            name: ornith-dsh:latest
            input:
              - text
              - image
            contextWindow: 128000
            maxTokens: 4096
```

Use `dsh --profile <name> --dump-config` (unconfined shell, see §5) to confirm the composed file parses after you edit. If it fails on other machines, that's a syntax error — fix before the next run.

---

## 3. Edit the model entry (the actual fix)

Add/update the entry so `contextWindow` matches the built-in context and `maxTokens` caps just below it:

```yaml
          - id: ornith-dsh:latest
            name: ornith-dsh:latest
            input:
              - text
              - image
            contextWindow: 128000     # must equal the model's built-in num_ctx (128000)
            maxTokens: 4096           # below num_predict so the cap applies
```

If the entry *isn't* there, paste it inside the same route's `models:` sequence at the right indentation (keep YAML column alignment on `- id:`, `name:`, etc.).

### Ollama is a gateway — add `compat.maxTokensField`

Ollama answers OpenAI-compatible calls over a `/v1` URL, and `num_predict` in the Modelfile is only its **default**. If a request names no cap it keeps 16384 and nothing in DSH can override it via the `models` sequence. The fix (route-wide) is on the localollama route:

```yaml
      localollama:
        displayName: Local Ollama
        api: openai-completions
        baseURL: http://127.0.0.1:11434/v1
        compat:
          maxTokensField: max_tokens   # Ollama understands this instead of "max_completion_tokens"
        models:
```

A model's own `compat` also works field-by-field (leave `supportsThinkingFormat` unless it needs a different role shape). Prefer the `maxTokens: 4096` on the entry when you already have that compat, since a route-level default applies to every model on the route.

See `C:\AI\deepseek-harness\docs\user\guide\providers.md#request-compatibility` for the gateway/compat primer.

---

## 4. Sanity check (which layer wins)

`maxTokens` is **always** stronger than Ollama's Modelfile default on both sides:

- **Model stricter → config lifted:** `PARAMETER num_predict: 16`, no cap, reply gets ~16 tokens; adding `max_tokens: 64` in the request allows 64.
- **Config stricter → model obeyed:** `PARAMETER num_predict: 16384` but `max_tokens: 8` → reply stops at 8 (`finish_reason: length`).

So on every machine, once `compat.maxTokensField: max_tokens` is set, any capped value in the config (`maxTokens`) takes effect regardless of `num_predict`. With `maxTokens: 4096` the cap wins because it's below 16384.

### ⚠️ Cautions on long-context / reasoning local models
- A model where the output budget is **shared with thinking tokens**: an overly small `maxTokens` can yield short or empty replies. 4096 is safe for most but watch for that shape. If you want less cap risk, raise `contextWindow` to 262144 before lowering `maxTokens`.
- **Consistency matters:** keep `contextWindow` near/inside the real window so DSH's ~0.8× compaction reserve doesn't run out. Mismatched numbers will hurt long sessions.
- **`id` is sent verbatim as `model`:** if you edited the tag, use the *same* tag in `id` and `name`. Pick it manually in the model picker (`--default-model` still points DeepSeek elsewhere, so manual pick keeps `localollama/ornith-dsh-...`).

---

## 5. Verify (read-only first, then a live turn)

**In-profile parse / config dump** — unconfined shell:

```powershell
node "$env:DSH_HOME/../.."                    # bring dsh up if absent
& "C:\AI\deepseek-harness\apps\cli\lib\bin.js" --profile <name> --dump-config
```

Caveat: `--dump-config` calls into the live profile dir and **can throw `EPERM … cordis.yml`** where a confined/locked state blocks writes. If it does, edit the file directly instead (that's what this doc teaches). Confirm in its output that the localollama route lists `maxTokens: 4096`.

**Gui check:** Trajectory view → pick a local request → **Request options JSON** → expect `"maxTokens": 4096` and `contextWindow` aligned. If absent after edit, restart (`ds -p <<profile>>`) so the profile patch layer reloads. Wait for Ollama to reload too (Ollama never reads DSH's patch directly — the patch only drives the emitted request — so a *request* is enough; only a full restart reloads its modelfile).

**Session store check:** sessions are zstd JSONL (`session.v4.jsonl.zstd`). A header event now records `data.header.config: {"provider":"localollama","model":"ornith-dsh:latest","maxTokens":4096}`; a compaction event can show reserved completion tokens. A model whose header says no cap but replies as capped would be the tell of an undelivered patch. Historically every local request recorded only `{provider, model}` with no maxTokens — its presence is proof the compat mapping landed.

**Live smoke test:** `Please count to 10` on a fresh long session near the true window (history ~65k tokens) should now come back fully, because context isn't the limiter and the capped output still fits. A short/empty reply = cap too small (see §3).

---

## 6. What you changed (for history / rollback)

One patch file per profile, changing two fields on the model entry + one route-level compat key:

| Field | Before | After | Why |
|---|---|---|---|
| `contextWindow` | e.g. 65536 | **128000** (built-in num_ctx) | window no longer half of real room |
| `maxTokens` | e.g. max none / wrong key | **4096** (below num_predict 16384) | cap now applies and fits the window |
| route `compat.maxTokensField` | *(absent)* | **`max_tokens`** | route-wide Ollama output-cap mapping |

Rollback is symmetric: delete those keys + set `contextWindow` back to what `_show` reported, and because it's live-reload the change reverts on save. Nothing else needed.
```
---
```
