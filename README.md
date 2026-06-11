# awake — macOS app-control experiment

How far can a plain **bash + AppleScript (`osascript`)** script drive the apps
already open on a Mac, using only *legitimate* automation surfaces?

`awake.sh` randomly rotates focus across your visible apps every 30–60 seconds,
raises specific windows, switches native tabs where the app exposes a scripting
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
  a real input event does. `ENABLE_MOUSE_JIGGLE` (below) nudges the cursor 1px
  and restores it each tick, which posts a real event and resets the timer.
  This is synthetic input, so it is **off by default and labeled in the logs**,
  like `ENABLE_KEYBOARD_TAB_CYCLE`. Requires `cliclick` (`brew install cliclick`).

Run `./awake.sh --jiggle-test` to confirm it works: it prints the idle time
before and after a jiggle — a pass means idle dropped to ~0.

Run `--probe` first (with Safari, Ghostty, DBeaver, VS Code open) to confirm what
your machine exposes, then paste the table into [`CAPABILITIES.md`](./CAPABILITIES.md).

For a quick interactive test with faster actions:

```bash
MIN_SLEEP=3 MAX_SLEEP=6 TILE_PROBABILITY=0 ./awake.sh
```

To also cycle Ghostty tabs and VS Code open editors/files, opt into synthetic
app hotkeys:

```bash
MIN_SLEEP=3 MAX_SLEEP=6 TILE_PROBABILITY=0 ENABLE_KEYBOARD_TAB_CYCLE=true ./awake.sh
```

## Tunables

Edit the **Config block** at the top of `awake.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_SLEEP` / `MAX_SLEEP` | `30` / `60` | Random wait (seconds) between actions |
| `TILE_PROBABILITY` | `25` | % of ticks that tile two apps instead of single-focus |
| `MENU_BAR_INSET` | `25` | Pixels reserved at the top of the screen when tiling |
| `ENABLE_TAB_SWITCH` | `true` | Switch Safari tabs via its AppleScript dictionary |
| `ENABLE_KEYBOARD_TAB_CYCLE` | `false` | **Opt-in.** Synthetic app-hotkey tab cycling for apps with no dictionary (Ghostty/VS Code/DBeaver). Keymaps are best-guesses — adjust to your bindings. |
| `ENABLE_MOUSE_JIGGLE` | `false` | **Opt-in.** Imperceptible 1px cursor nudge each tick that resets the HID idle timer (look "present"). Synthetic input; needs `cliclick`. |
| `MOUSE_JIGGLE_PX` | `1` | Pixels to nudge before restoring the cursor to its exact original spot. |
| `EXCLUDE_APPS` | `()` | App/process names to never select |
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
