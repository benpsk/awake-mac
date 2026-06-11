# Capability map

How far `awake.sh` can drive each app, by control layer. The **Predicted** column
is the expectation going in; fill **Observed** by running `./awake.sh --probe` on
your Mac (with the apps open) and watching the rotation logs.

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
(synthetic input, gated behind `ENABLE_KEYBOARD_TAB_CYCLE`).

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
via genuine posted input — gated behind `ENABLE_MOUSE_JIGGLE` and provable with
`./awake.sh --jiggle-test` (idle before vs after).

## Takeaway

The robust path is **not** generic faked input — it's each app's *real* automation
surface. Safari is fully scriptable (focus + windows + tabs + tiling). Ghostty,
DBeaver, and VS Code top out at the window/focus layer because they ship no
AppleScript dictionary, and their internal UI (tabs, trees, panels) lives behind
Electron/SWT canvases that the Accessibility API barely exposes. That boundary —
window-level ✅, tab-level only-where-scriptable, internal-panels ❌ — is the
experiment's main finding.
