# awake — app-control experiment for macOS and Windows

How far can plain platform scripts drive the apps already open on a machine,
using each OS's normal automation/input surfaces?

`awake.sh` randomly rotates focus across your visible macOS apps every 30–60 seconds,
excluding Terminal by default so the shell running the script is not selected.
It raises specific windows, switches native tabs where the app exposes a scripting
dictionary, and occasionally tiles two apps side-by-side. A `--probe` mode prints
a live capability map so you can see exactly what each app on *your* machine allows.

`awake.ps1` is the Windows 10+ sibling: it rotates focus across visible windows,
maximizes or tiles them, and prevents normal system/display sleep while running.
In `ENABLE_ALL=true` mode it adds Chrome/Postman tab switching and scrolling,
VS Code editor/scroll/unique workspace-file actions, and cursor movement via Win32 `SendInput`.
CMD, PowerShell, and Windows Terminal remain focus-only.

> This is a capability demo. It does **not** fake user input to deceive anyone.
> Synthetic keystrokes and cursor movement are **off by default** and clearly
> labeled in the logs.

## Requirements

### macOS

- macOS (works with the stock `/bin/bash` 3.2; no extra installs)
- **Accessibility permission** for the terminal app you run it from:
  System Settings → Privacy & Security → Accessibility → enable Terminal / Ghostty / iTerm.
  The first `osascript` call that drives another app will prompt for this.
  Without it, System Events calls silently do nothing.
- **`cliclick`** — only for the cursor movement in active mode (`ENABLE_ALL=true`):
  `brew install cliclick`. Not needed for focus/window/tile rotation.

### Windows

- Windows 10 or newer.
- Built-in Windows PowerShell is enough; no extra install is required.
- `awake.ps1` uses Win32 APIs directly: `SetThreadExecutionState`,
  `SetForegroundWindow`, and `SendInput`.

## Usage

### macOS

```bash
chmod +x awake.sh

./awake.sh              # start the random focus / tile rotation (Ctrl+C to stop)
./awake.sh --probe      # print a capability map for the target apps and exit
./awake.sh --jiggle-test # prove the mouse jiggle resets the HID idle timer
./awake.sh --help       # show help
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\awake.ps1
powershell -ExecutionPolicy Bypass -File .\awake.ps1 --probe
powershell -ExecutionPolicy Bypass -File .\awake.ps1 --jiggle-test
powershell -ExecutionPolicy Bypass -File .\awake.ps1 --help
```

## Staying awake: sleep vs presence

Two different problems, two different tools:

- **Stop macOS sleeping** → use the built-in `caffeinate` (no input faked,
  no Accessibility needed): `caffeinate -dimsu ./awake.sh`.
- **Stop Windows sleeping** → `awake.ps1` calls `SetThreadExecutionState`
  while it is running.
- **Look *active/present*** to apps (Slack green dot, idle timers) →
  those watch the **HID idle timer**, which `caffeinate` does *not* reset. Only
  a real input event does. Active mode (`ENABLE_ALL=true`, below) moves the
  cursor to a random on-screen point each tick, which posts an input event and
  resets the timer. This is synthetic input, so it is **off by default and
  labeled in the logs**. macOS requires `cliclick` (`brew install cliclick`);
  Windows uses built-in `SendInput`.

Run `./awake.sh --jiggle-test` to confirm it works: it prints the idle time
before and after a jiggle — a pass means idle dropped to ~0.

On Windows, run `powershell -ExecutionPolicy Bypass -File .\awake.ps1 --jiggle-test`
to confirm `SendInput` can move the cursor out and back.

On macOS, run `--probe` first (with Safari, Ghostty, DBeaver, VS Code open) to
confirm what your machine exposes, then paste the table into
[`CAPABILITIES.md`](./CAPABILITIES.md).

For a quick interactive test with faster actions:

```bash
MIN_SLEEP=3 MAX_SLEEP=6 TILE_PROBABILITY=0 ./awake.sh
```

For the macOS **full active mode** — Safari tab switching, synthetic-keystroke
actions (Ghostty/VS Code tab cycling, Safari + VS Code scrolling, the occasional
unique VS Code workspace-file open), and random cursor movement — flip the single
master switch `ENABLE_ALL`:

```bash
ENABLE_ALL=true ./awake.sh
```

Windows:

```powershell
$env:ENABLE_ALL="true"
powershell -ExecutionPolicy Bypass -File .\awake.ps1
```

Windows active-mode mappings:

| App | Active action |
|---|---|
| Chrome | `Ctrl+Tab`, then `Page Up` or `Page Down` |
| Postman | `Ctrl+Tab`, then `Page Up` or `Page Down` |
| VS Code | `Ctrl+PageDown`, scrolling, and occasional unique workspace-file opening |
| CMD / PowerShell / Windows Terminal | Focus only; no synthetic keystrokes |

Before sending a shortcut, the Windows script confirms that the intended window
is still foreground. It protects the terminal window that launched the script,
while allowing other terminal windows to participate in rotation.

Cursor movement needs `cliclick` (`brew install cliclick`); without it that one
macOS action logs a skip and everything else still runs. Windows has no external
cursor-movement dependency.

> In active mode, synthetic keystrokes are sent to whatever app is frontmost.
> Scrolling and tab cycling are read-only. VS Code files are opened by absolute
> path through the platform launcher and are never edited. Ghostty is
> deliberately limited to **tab cycling only** — no keystrokes are sent into
> terminal content.

## Tunables

Edit the **Config block** at the top of `awake.sh`, or set environment variables
for either script:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_SLEEP` / `MAX_SLEEP` | `30` / `60` | Random wait (seconds) between actions |
| `TILE_PROBABILITY` | `25` | % of ticks that tile two windows instead of maximizing one |
| `MENU_BAR_INSET` | `25` | macOS only: pixels reserved at the top of the screen when tiling |
| `ENABLE_ALL` | `false` | **Single master switch.** Enables platform app actions and random cursor movement. |
| `VSCODE_OPEN_FILE_PROBABILITY` | `30` | % of VS Code focuses that open a unique workspace file. |
| `VSCODE_RANDOM_FILE_CYCLE_SIZE` | `20` | Unique code/text files opened per workspace before reshuffling. |
| `MOUSE_JIGGLE_PX` | `1` | Nudge size (px) for the jiggle fallback and `--jiggle-test`. |
| `EXCLUDE_APPS` | platform default | Built-in names to never select. macOS excludes `Terminal`; Windows excludes shell-only surfaces and protects the exact runner window. |
| `AWAKE_EXCLUDE_APPS` (env) | unset | Comma-separated extra app/process/window names to never select, for example `AWAKE_EXCLUDE_APPS="Finder,Music" ./awake.sh`. |
| `AWAKE_LOG_FILE` (env) | unset | Also append timestamped logs to this file |

All scalar tunables can be overridden from the environment for one run, as shown
above.

## What it can and can't reach

| Layer | How | Reliable? |
|---|---|---|
| App focus | System Events `activate` / `set frontmost` | ✅ everywhere |
| Window raise / list | System Events `AXRaise`, `count windows` | ✅ most apps |
| Native tabs | App's AppleScript dictionary | ✅ Safari · ❌ Ghostty/VS Code/DBeaver (no dictionary) |
| Window tiling | dictionary `bounds` or System Events `position`/`size` | ✅ native apps · ⚠️ Electron may ignore |
| Internal panels (file tree, DB navigator, request collections) | Accessibility tree | ❌ Electron/Java-SWT expose little to nothing |

See [`CAPABILITIES.md`](./CAPABILITIES.md) for the detailed findings.

On Windows, window focus/raise/maximize/tiling uses Win32 APIs. Chrome and Postman
use foreground-verified shortcuts. VS Code also uses its installed CLI to open a
shuffled set of unique code/text files from the matched local workspace. Each
workspace has an independent in-memory cycle; after 20 files (or all eligible
files in a smaller workspace), the set is rebuilt and reshuffled. Restarting
`awake.ps1` resets this state. Other visible apps participate at the window level.

On macOS, VS Code uses the same per-workspace unique-file cycle. Workspace state
is held in a script-owned temporary directory because the stock Bash 3.2 lacks
associative arrays; Ctrl+C and normal shutdown remove it. The built-in `open`
command opens each selected path, so no VS Code CLI installation is required.

## Notes & limits

- Tiling targets the **main display only**.
- VS Code (Electron) and DBeaver (Java/SWT) expose a poor/empty Accessibility
  tree, so their internal panels and editor tabs are not reachable via a clean API.
- Ghostty has no AppleScript dictionary → window-level control only.
- Secure input fields (passwords) and sandboxed apps further restrict control.
- App names in the rotation come from process names (e.g. VS Code reports as `Code`).
