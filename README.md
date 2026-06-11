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

./awake.sh            # start the random focus / tile rotation (Ctrl+C to stop)
./awake.sh --probe    # print a capability map for the target apps and exit
./awake.sh --help     # show help
```

Run `--probe` first (with Safari, Ghostty, DBeaver, VS Code open) to confirm what
your machine exposes, then paste the table into [`CAPABILITIES.md`](./CAPABILITIES.md).

## Tunables

Edit the **Config block** at the top of `awake.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_SLEEP` / `MAX_SLEEP` | `30` / `60` | Random wait (seconds) between actions |
| `TILE_PROBABILITY` | `25` | % of ticks that tile two apps instead of single-focus |
| `MENU_BAR_INSET` | `25` | Pixels reserved at the top of the screen when tiling |
| `ENABLE_TAB_SWITCH` | `true` | Switch Safari tabs via its AppleScript dictionary |
| `ENABLE_KEYBOARD_TAB_CYCLE` | `false` | **Opt-in.** Synthetic app-hotkey tab cycling for apps with no dictionary (Ghostty/VS Code/DBeaver). Keymaps are best-guesses — adjust to your bindings. |
| `EXCLUDE_APPS` | `()` | App/process names to never select |
| `AWAKE_LOG_FILE` (env) | unset | Also append timestamped logs to this file |

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
