# awake — macOS app-control experiment

How far can a plain **bash + AppleScript (`osascript`)** script drive the apps
already open on a Mac, using only *legitimate* automation surfaces?

`awake.sh` randomly rotates focus across your visible apps every 30–60 seconds,
excluding Terminal by default so the shell running the script is not selected.
It raises specific windows, switches native tabs where the app exposes a scripting
dictionary, and occasionally tiles two apps side-by-side. A `--probe` mode prints
a live capability map so you can see exactly what each app on *your* machine allows.

> This is a capability demo. It does **not** fake user input to deceive anyone.
> The only spot a synthetic keystroke can occur (cycling tabs in apps that have
> no scripting dictionary) is **off by default** and clearly labeled in the logs.

## Requirements

- macOS (works with the stock `/bin/bash` 3.2; no extra installs)
- **Accessibility permission** for the terminal app you run it from:
  System Settings → Privacy & Security → Accessibility → enable Terminal / Ghostty / iTerm.
  The first `osascript` call that drives another app will prompt for this.
  Without it, System Events calls silently do nothing.
- **`cliclick`** — only for the cursor movement in active mode (`ENABLE_ALL=true`):
  `brew install cliclick`. Not needed for focus/window/tile rotation.

## Usage

```bash
chmod +x awake.sh

./awake.sh              # start the random focus / tile rotation (Ctrl+C to stop)
./awake.sh --probe      # print a capability map for the target apps and exit
./awake.sh --jiggle-test # prove the mouse jiggle resets the HID idle timer
./awake.sh --help       # show help
```

## Staying awake: sleep vs presence

Two different problems, two different tools:

- **Stop the Mac sleeping** → use the built-in `caffeinate` (no input faked,
  no Accessibility needed): `caffeinate -dimsu ./awake.sh`.
- **Look *active/present*** to apps (Slack green dot, corporate idle timers) →
  those watch the **HID idle timer**, which `caffeinate` does *not* reset. Only
  a real input event does. Active mode (`ENABLE_ALL=true`, below) moves the cursor
  to a random on-screen point each tick, which posts a real event and resets the
  timer. This is synthetic input, so it is **off by default and labeled in the
  logs**. Requires `cliclick` (`brew install cliclick`).

Run `./awake.sh --jiggle-test` to confirm it works: it prints the idle time
before and after a jiggle — a pass means idle dropped to ~0.

Run `--probe` first (with Safari, Ghostty, DBeaver, VS Code open) to confirm what
your machine exposes, then paste the table into [`CAPABILITIES.md`](./CAPABILITIES.md).

For a quick interactive test with faster actions:

```bash
MIN_SLEEP=3 MAX_SLEEP=6 TILE_PROBABILITY=0 ./awake.sh
```

For the **full active mode** — Safari tab switching, synthetic-keystroke actions
(Ghostty/VS Code tab cycling, Safari + VS Code scrolling, the occasional VS Code
`Cmd+P` random-file open), and random cursor movement — flip the single master
switch `ENABLE_ALL`:

```bash
ENABLE_ALL=true ./awake.sh
```

Cursor movement needs `cliclick` (`brew install cliclick`); without it that one
action logs a skip and everything else still runs.

> In active mode, synthetic keystrokes are sent to whatever app is frontmost.
> Scrolling and tab cycling are read-only; the VS Code `Cmd+P` open only navigates
> (worst case a stray `Enter` adds one newline, undoable with `Cmd+Z`). Ghostty is
> deliberately limited to **tab cycling only** — no keystrokes are sent into
> terminal content.

## Tunables

Edit the **Config block** at the top of `awake.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_SLEEP` / `MAX_SLEEP` | `30` / `60` | Random wait (seconds) between actions |
| `TILE_PROBABILITY` | `25` | % of ticks that tile two apps instead of single-focus |
| `MENU_BAR_INSET` | `25` | Pixels reserved at the top of the screen when tiling |
| `ENABLE_ALL` | `false` | **Single master switch.** `true` = full active mode: Safari tab switching, synthetic keystrokes (Safari/VS Code scroll, Ghostty/VS Code/DBeaver tab cycle, VS Code `Cmd+P` file open), and random cursor movement. `false` = focus/tile/window rotation only. Cursor movement needs `cliclick`. |
| `VSCODE_OPEN_FILE_PROBABILITY` | `30` | % of VS Code focuses that open a random recent file via `Cmd+P`. |
| `VSCODE_OPEN_FILE_MAX_STEPS` | `8` | Max down-arrows into the `Cmd+P` recent list before `Enter`. |
| `MOUSE_JIGGLE_PX` | `1` | Nudge size (px) for the jiggle fallback and `--jiggle-test`. |
| `EXCLUDE_APPS` | `("Terminal")` | App/process names to never select. This keeps macOS Terminal from being focused while it runs the script. |
| `AWAKE_EXCLUDE_APPS` (env) | unset | Comma-separated extra app/process names to never select, for example `AWAKE_EXCLUDE_APPS="Finder,Music" ./awake.sh`. |
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

## Notes & limits

- Tiling targets the **main display only**.
- VS Code (Electron) and DBeaver (Java/SWT) expose a poor/empty Accessibility
  tree, so their internal panels and editor tabs are not reachable via a clean API.
- Ghostty has no AppleScript dictionary → window-level control only.
- Secure input fields (passwords) and sandboxed apps further restrict control.
- App names in the rotation come from process names (e.g. VS Code reports as `Code`).
