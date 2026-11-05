# DSH Tools

Machine-local tools for DeepSeek Harness: a shared skill, one local plugin, and the
installer that puts both in place on a new machine.

| Path | What it is |
|---|---|
| `skills/grab-window/` | Agent skill + `grab-window.ps1`: capture a PNG of a Windows window or desktop region |
| `local-datetime/` | DSH plugin `@local/dsh-tool-local-datetime`: the host's current date and time |
| `install.ps1` | Idempotent installer: skill-root junction, PATH shims, plugin registration |
| `INSTALL.md` | Prerequisites, options, manual equivalent, uninstall |
| `MakeOrnithWorkWithDSH.md` | Notes for getting long-context Ollama models working on another machine |
| `FixBashSandboxOnLinux.md` | Linux: why every shell command fails with `no sandbox backend is usable`, and how to fix both backends |

## Install on a new machine

```powershell
git clone https://github.com/kevinwross/dshTools.git "C:\Users\<you>\source\repos\DSH Tools"
cd "C:\Users\<you>\source\repos\DSH Tools"
pwsh -NoProfile -File .\install.ps1
```

Re-running is safe: missing pieces are created, everything else is reported as skipped.
See [INSTALL.md](INSTALL.md) for prerequisites, flags, and the manual equivalent.
