# Capability map

How far each platform script can drive an app, by control layer. The macOS
**Predicted** column is the expectation going in; fill **Observed** by running
`./awake.sh --probe` on your Mac and watching the rotation logs.

## Windows capability map

`awake.ps1 --probe` lists every eligible visible window and labels its behavior.
All visible applications participate in focus, maximize, and tiling; active-mode
shortcuts are limited to recognized targets.

| App | Focus/window | Tabs | Scroll | File open | Safety |
|---|---|---|---|---|---|
| **Chrome** | Win32 | `Ctrl+Tab` | Page keys | n/a | Foreground verified |
| **Postman** | Win32 | `Ctrl+Tab` | Page keys | n/a | Foreground verified |
| **VS Code** | Win32 | `Ctrl+PageDown` | Page keys | Unique workspace queue via CLI | Foreground verified |
| **CMD / PowerShell / Windows Terminal** | Win32 | Disabled | Disabled | n/a | Focus-only |

The exact terminal window that launched `awake.ps1` is excluded by window handle;
other terminals remain eligible. All keyboard and mouse input is opt-in through
`ENABLE_ALL=true`.

Windows resolves each VS Code window through its local workspace metadata, builds
a code/text-only file pool, and opens each selected path at most once per cycle.
Cycles are independent per workspace and remain in memory only. Remote-only or
unresolved workspaces are skipped safely.

## macOS capability map

## Control layers

1. **App focus** — bring an app to the foreground (`activate` / `set frontmost`).
2. **Window** — list and raise a specific window (`AXRaise`).
3. **Tabs** — switch native tabs (only via an app's AppleScript dictionary).
4. **Tiling** — set window position/size (left/right half).
5. **Internal panels** — sidebars, file trees, DB navigators, request collections
   (only via the Accessibility tree).

## Predicted (target apps)

| App | Engine | Focus | Window | Tabs | Tiling | Internal panels |
|---|---|---|---|---|---|---|
| **Safari** | WebKit / Cocoa | ✅ | ✅ | ✅ dictionary (`tabs`, `current tab`) | ✅ | n/a |
| **Ghostty** | native AppKit | ✅ | ✅ | ❌ no dictionary (hotkey only, opt-in) | ✅ | limited |
| **DBeaver CE** | Java / SWT (Eclipse) | ✅ | ⚠️ usually OK | ❌ no dictionary | ⚠️ may resist | ❌ SWT AX poor |
| **VS Code** | Electron | ✅ | ✅ | ❌ no dictionary (hotkey only, opt-in) | ⚠️ Electron may ignore | ❌ AX tree ~empty |

Legend: ✅ works via a real API · ⚠️ works sometimes / app-dependent · ❌ no clean
path · *hotkey only* = reachable only by sending the app's own keyboard shortcut
(synthetic input, gated behind the `ENABLE_ALL` master switch).

Beyond tabs, the same synthetic-keystroke surface (also under `ENABLE_ALL`) drives
**scrolling** in Safari and VS Code via Page Up/Down. VS Code file opening uses a
per-workspace shuffled queue of unique code/text paths and macOS's built-in `open`
command, not keyboard input. Ghostty is held to tab cycling only — no keystrokes
are sent into terminal content, since the script can't tell vim from a shell in
the focused tab.

## Observed on this machine

Paste `./awake.sh --probe` output here:

```
APP                    RUNNING   WINDOWS   TABS     GEOMETRY
---                    -------   -------   ----     --------
Safari                 ?         ?         ?        ?
Ghostty                ?         ?         n/a      ?
Code                   ?         ?         n/a      ?
DBeaver                ?         ?         n/a      ?
```

Notes / surprises (e.g. did VS Code tiling actually take? did DBeaver windows raise?):

- …

## Mouse / idle timer

Moving the cursor is the one action with **no** AppleScript surface — `osascript`
has no native "move mouse". A real move needs `cliclick` (or `CGEventPost`). Note
the trap: `CGWarpMouseCursorPosition` *teleports* the cursor but does **not**
reset the HID idle timer, so apps still consider you away. `cliclick m:` posts a
real `CGEvent`, which **does** reset it. So "look present" is reachable, but only
via genuine posted input — gated behind `ENABLE_ALL` and provable with
`./awake.sh --jiggle-test` (idle before vs after).

## Takeaway

The robust path is **not** generic faked input — it's each app's *real* automation
surface. Safari is fully scriptable (focus + windows + tabs + tiling). Ghostty,
DBeaver, and VS Code top out at the window/focus layer because they ship no
AppleScript dictionary, and their internal UI (tabs, trees, panels) lives behind
Electron/SWT canvases that the Accessibility API barely exposes. That boundary —
window-level ✅, tab-level only-where-scriptable, internal-panels ❌ — is the
experiment's main finding.
