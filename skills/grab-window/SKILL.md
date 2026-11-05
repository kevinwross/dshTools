---
name: grab-window
description: Capture a PNG of a single Windows window or a desktop region. Use when you need to see an app's actual pixels — verifying a GUI change, reading a screenshot the user described, or confirming that something rendered.
---

# grab-window

Capture a PNG of one window (or a desktop region). Single file, no dependencies,
Windows PowerShell 5.1 and 7+.

`grab-window.ps1` sits beside this file. It is also exposed as `grab-window` on PATH via
`%USERPROFILE%\.local\bin\grab-window.cmd` — that is the form the examples use, and it
works from any project directory. If the command is missing, call the script by its full
path instead. The command returns a PNG path; you cannot see the image until you open it
with an image-capable tool (`read_image` in DSH, or any viewer).

## 1. Preconditions

| Requirement | Check |
|---|---|
| Windows | `$env:OS -eq 'Windows_NT'` |
| PowerShell 5.1+ | `$PSVersionTable.PSVersion.Major -ge 5` |
| Interactive desktop session | capture returns black if the host is a service or a disconnected session |
| Sandbox permits `Add-Type` | probe below |

Probe it in one line before blaming the script:

```powershell
try { Add-Type -AssemblyName System.Drawing; 'capable' } catch { 'blocked: ' + $_.Exception.Message }
```

`blocked:` means the sandbox or the OS, not the tool. Under a read-only sandbox
PowerShell runs in ConstrainedLanguage, `Add-Type` fails, and nothing here can work —
escalate the sandbox or use a different approach. Do not retry blindly.

## 2. Inventory first

```powershell
grab-window -List
```

Prints one row per capturable window: `Hwnd`, `ProcessId`, `ProcessName`, `Title`,
`Size`, `Minimized`.

The list excludes invisible windows, windows with no title, and DWM-cloaked windows
(UWP ghosts, other virtual desktops). If a window the user named is missing, it is one
of those three — ask the user to restore or focus it.

## 3. Capture

Pick the most specific selector available. Prefer `-Hwnd`: titles change when a document
is opened or renamed, and duplicate titles are common (every Explorer window, every
Notepad).

```powershell
# by handle — preferred, unambiguous
grab-window -Hwnd 14945506 -Path shots\app.png

# by title: exact match first, then -like wildcard, then substring
grab-window -Title 'KR16 - C-for-U.c' -Path shots\app.png
grab-window -Title '*KR16*'          -Path shots\app.png

# by process id (all visible windows of that process; must be unique)
grab-window -ProcessId 3976 -Path shots\app.png

# whatever is in front right now
grab-window -Window -Path shots\front.png

# desktop rectangle: x,y,width,height in virtual-desktop pixels
grab-window -Region -Bounds 0,0,1280,720 -Path shots\corner.png

# every monitor combined (virtual screen)
grab-window -Region -Path shots\all-monitors.png
```

Capture the object, not the console text, when you need to act on the result:

```powershell
$shot = grab-window -Hwnd 14945506 -Path shots\app.png
if ($shot.Blank) { throw 'capture was uniform; inspect before retrying' }
$shot.Path   # absolute path, already inside the workspace
```

## 4. Parameters

| Parameter | Applies to | Default | Meaning |
|---|---|---|---|
| `-Title` | window | — | Window title. Exact (case-insensitive) → wildcard `-like` → substring. Ambiguous or missing matches fail with the candidate list. |
| `-ProcessId` (alias `-Pid`) | window | — | Owning process. Fails if it owns several visible windows. |
| `-Hwnd` | window | — | Raw window handle. Skips all matching; use when titles repeat. |
| `-Window` | foreground | — | Capture the foreground window, no other selector. |
| `-Region` | region | — | Capture desktop pixels instead of a window. |
| `-Bounds` | region | full virtual screen | `x,y,width,height`. Negative `x`/`y` are valid on monitors left of or above the primary. |
| `-Method` | both | `Auto` | `Auto`, `PrintWindow`, or `Screen`. See §6. |
| `-Path` | both | `capture-<timestamp>.png` in the current directory | Output `.png`. Relative paths resolve against the caller's directory; absolute paths are accepted as-is; missing parent directories are created; a missing extension gets `.png`; other extensions are rejected. |
| `-List` | — | off | Print the window inventory and exit. |

## 5. Output contract

One object per successful capture, exit code 0:

| Field | Meaning |
|---|---|
| `Path` | Absolute path of the written PNG. |
| `Method` | `PrintWindow` or `Screen` — **which path actually produced the file**, not which one you asked for. |
| `Width`, `Height` | Pixel dimensions of the saved PNG. Always trust these over any window geometry. |
| `Hwnd`, `Title`, `ProcessId`, `ProcessName` | The resolved target. `ProcessName` may be `unknown` when the sandbox denies process enumeration; that is cosmetic and does not affect the capture. |
| `Minimized` | Window was minimized at capture time. |
| `Blank` | `True` when the sampled frame is a single uniform color — almost always a refused render. |
| `DpiMode` | `per-monitor-v2`, `system`, or `inherited`. |
| `Note` | Non-fatal explanation, e.g. that a fallback happened. |
| `Bytes` | File size. |

Treat a capture as unusable when `Blank -eq $True`, and as *possibly* usable when `Note`
mentions a screen crop. A legitimately uniform window (a blank editor, a solid splash)
can also report `Blank`; open the PNG to decide before re-running.

## 6. Method semantics — read this before trusting a capture

| Method | Sees | Blind spots |
|---|---|---|
| `PrintWindow` | The app's own render into a bitmap, using `PW_RENDERFULLCONTENT`. Works on occluded, unfocused windows. | GPU-composited apps (Chromium, Electron, some games) return a blank or stale frame. Minimized windows may be blank. |
| `Screen` | The pixels actually on screen inside the window rectangle (or `-Bounds`). | Anything overlapping the rectangle is captured instead. Minimized windows are rejected outright. |

`Auto` (default) tries `PrintWindow` first, falls back to `Screen` when the frame comes
back uniform and the window is not minimized, and records that in `Note`. If you need to
know whether a capture is occlusion-proof, require `Method -eq 'PrintWindow'` and
`Blank -eq $False`; a `Screen` result proves what was displayed, not what the app
contains.

DPI awareness is raised to per-monitor v2 so rectangles and pixels agree on scaled
displays. A host that already fixed its DPI mode is left alone.

## 7. Failure messages → what to do

Every failure is a terminating error: exit code 1, message on stderr.

| Message contains | Meaning | Action |
|---|---|---|
| `No window title matches '…'. Available windows:` | Title wrong, or window hidden/cloaked. | Re-run `-List`; use the exact title or `-Hwnd`. |
| `matches N windows; pass -Hwnd` | Duplicate titles. | Pick one `Hwnd` from the listed candidates. |
| `No visible window belongs to process id N.` | Pid wrong, or it has no visible top-level window. | Verify with `-List`; the pid there is the window's owner, not a guess. |
| `Process id N owns N windows; pick one with -Hwnd` | Multi-window process. | Disambiguate by handle. |
| `The target window is minimized; restore it or use -Method PrintWindow.` | `-Method Screen` on a minimized window. | Switch method, or ask the user to restore the window. |
| `No foreground window to capture.` | Nothing focused. | Use an explicit selector. |
| `Only PNG output is supported; got '…'` | Non-`.png` path. | Change the extension. |
| `Bounds must be x,y,width,height (four integers).` | Malformed `-Bounds`. | Pass exactly four integers. |
| `Refusing a zero-area capture` | Region or window has no area. | Fix `-Bounds` or pick another window. |
| `Add-Type`, `System.Drawing`, or `ConstrainedLanguage` errors | Read-only sandbox, or non-Windows. | Escalate the sandbox; do not retry the same command. |
| `Specify -Title, -ProcessId or -Hwnd…` | No selector given. | Add one, or use `-Window` / `-Region` / `-List`. |

## 8. Working with the result

1. Capture into the workspace (relative `-Path`, e.g. `shots\app.png`).
2. Open the file with an image-capable tool — `read_image` on `$shot.Path` in DSH.
3. Describe what you see before drawing conclusions; do not infer UI state from the fact
   that the command succeeded.
4. Delete throwaway captures when done, or keep them only as deliberate evidence.

Each invocation is a fresh process, so there is no state to carry between calls — pass
the selector again every time. The script is not a model-visible tool: it has no schema
and does not appear in any tool list. Verifying that a change actually rendered remains
your responsibility.

## 9. Boundaries

- **Windows only.** Win32/GDI dependencies; nothing here ports elsewhere.
- **Pixels, not semantics.** No UI tree, no element clicking, no snapshot or staleness
  handling. For element-level desktop automation use a computer-use provider instead.
- **No video, no clipboard, no annotation.** One still frame per call.
- **Privacy.** A capture can contain the user's private content. Capture only windows
  relevant to the request, keep the files in the workspace, and delete them when they
  stop being needed. Never capture the full desktop when a window will do.
