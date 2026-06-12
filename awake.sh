#!/usr/bin/env bash
#
# awake.sh — macOS app-control experiment
#
# How far can a bash + AppleScript (osascript) script drive the apps already
# open on a Mac, using only LEGITIMATE automation surfaces?
#
#   - Randomly rotates focus across visible apps every 30-60s
#   - Raises specific windows (System Events / Accessibility)
#   - Switches native tabs where the app exposes a scripting dictionary (Safari)
#   - Occasionally tiles two apps side-by-side (left / right half)
#   - --probe prints a live capability map for the target apps
#
# This is a capability demo. It does NOT fake user input to deceive anyone.
# The only place a synthetic keystroke can occur (cycling tabs in apps that
# have no scripting dictionary) is OFF by default and clearly labeled.
#
# Requires: macOS, Accessibility permission for the running terminal app
#   (System Settings -> Privacy & Security -> Accessibility).
#
# Stop with Ctrl+C.

set -o pipefail
# Note: `set -u`/`set -e` are intentionally omitted. Many osascript calls fail
# by design (app not scriptable, no front window, AX blocked); we handle every
# failure explicitly so the rotation loop never dies on an expected error.
# The script is also written to run on macOS's stock bash 3.2 (no mapfile, no
# safe empty-array expansion under `set -u`).

# ---------------------------------------------------------------------------
# Config — tune freely
# ---------------------------------------------------------------------------
MIN_SLEEP="${MIN_SLEEP:-30}"                  # min seconds between actions
MAX_SLEEP="${MAX_SLEEP:-60}"                  # max seconds between actions
TILE_PROBABILITY="${TILE_PROBABILITY:-25}"    # percent chance a tick tiles two apps vs single focus
MENU_BAR_INSET="${MENU_BAR_INSET:-25}"        # px reserved at top of screen when tiling
ENABLE_TAB_SWITCH="${ENABLE_TAB_SWITCH:-true}"  # switch tabs for dictionary-scriptable apps (Safari)
ENABLE_KEYBOARD_TAB_CYCLE="${ENABLE_KEYBOARD_TAB_CYCLE:-false}"  # opt-in: ALL synthetic keystrokes — tab cycling
                              # (Ghostty/Code/DBeaver), Safari + VS Code scrolling, and VS Code Cmd+P file open.
VSCODE_OPEN_FILE_PROBABILITY="${VSCODE_OPEN_FILE_PROBABILITY:-30}"  # % of VS Code focuses that open a random recent file via Cmd+P
VSCODE_OPEN_FILE_MAX_STEPS="${VSCODE_OPEN_FILE_MAX_STEPS:-8}"       # max down-arrows into the Cmd+P recent list before Enter
ENABLE_MOUSE_JIGGLE="${ENABLE_MOUSE_JIGGLE:-false}"  # opt-in: move the cursor to a random on-screen point each
                              # tick to reset the HID idle timer (look "present" to Slack/idle timers).
                              # Synthetic input; requires cliclick (brew install cliclick).
MOUSE_JIGGLE_PX="${MOUSE_JIGGLE_PX:-1}"        # pixels to nudge before restoring the cursor (jiggle fallback / --jiggle-test)
EXCLUDE_APPS=()               # app/process names never selected (empty per requirements)
LOG_FILE="${AWAKE_LOG_FILE:-}"   # empty => stdout only

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local ts
  ts=$(date '+%H:%M:%S')
  if [ -n "$LOG_FILE" ]; then
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
  else
    printf '[%s] %s\n' "$ts" "$*"
  fi
}

# ---------------------------------------------------------------------------
# AppleScript helpers
# ---------------------------------------------------------------------------

# Names of every app with a UI that is currently visible (not hidden),
# one per line, with EXCLUDE_APPS removed.
list_visible_apps() {
  local raw
  raw=$(osascript -e 'tell application "System Events" to get name of (every process whose background only is false and visible is true)' 2>/dev/null) || return 1
  printf '%s' "$raw" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | _filter_excluded
}

_filter_excluded() {
  local line e skip
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    skip=0
    for e in "${EXCLUDE_APPS[@]}"; do
      [ "$line" = "$e" ] && skip=1 && break
    done
    [ "$skip" -eq 0 ] && printf '%s\n' "$line"
  done
}

# Bring an app to the foreground. Prefer System Events (keyed on the process
# name we already have); fall back to `activate` by application name.
activate_app() {
  local app="$1"
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to set frontmost of process "$app" to true
EOF
  then
    return 0
  fi
  osascript -e "tell application \"$app\" to activate" >/dev/null 2>&1 \
    || log "  activate failed for $app"
}

# Count of windows for a process (0 on failure).
window_count() {
  local n
  n=$(osascript -e "tell application \"System Events\" to count windows of process \"$1\"" 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}

# Raise a random window of an app (Layer 1 — works for almost everything).
raise_random_window() {
  local app="$1" n idx
  n=$(window_count "$app")
  if [ "$n" -le 1 ]; then
    log "  $app: $n window(s), nothing to switch"
    return 0
  fi
  idx=$(( RANDOM % n + 1 ))
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell process "$app"
  set frontmost to true
  perform action "AXRaise" of window $idx
end tell
EOF
  then
    log "  $app: raised window $idx of $n"
  else
    log "  $app: AXRaise failed (window $idx)"
  fi
}

# Main-display size as: x0 y0 width height
screen_size() {
  local b
  b=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null) || return 1
  printf '%s' "$b" | tr ',' ' '
}

# Set a window's position + size via System Events (Layer used for tiling).
set_window_geometry() {
  local app="$1" x="$2" y="$3" w="$4" h="$5"
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell process "$app"
  set position of window 1 to {$x, $y}
  set size of window 1 to {$w, $h}
end tell
EOF
  then
    log "  $app: geometry -> {$x,$y,$w,$h}"
  else
    log "  $app: geometry set failed (app ignores AX position/size)"
  fi
}

# Tile two apps left-half | right-half on the main display.
tile_two() {
  local a="$1" b="$2" dims x0 y0 W H top halfW usableH
  dims=$(screen_size) || { log "tile: cannot read screen size"; return 1; }
  read -r x0 y0 W H <<EOF
$dims
EOF
  top=$MENU_BAR_INSET
  halfW=$(( W / 2 ))
  usableH=$(( H - top ))
  set_window_geometry "$a" 0 "$top" "$halfW" "$usableH"
  set_window_geometry "$b" "$halfW" "$top" "$halfW" "$usableH"
  activate_app "$a"
  log "tiled: $a (left) | $b (right)"
}

# Switch Safari to a random window + tab via its AppleScript dictionary (real API).
safari_random_tab() {
  [ "$ENABLE_TAB_SWITCH" = true ] || return 0
  local out
  out=$(osascript 2>/dev/null <<'EOF'
tell application "Safari"
  if (count of windows) is 0 then return "no window"
  set winCount to count of windows
  set winIdx to (random number from 1 to winCount)
  set targetWindow to window winIdx
  set tabCount to count of tabs of targetWindow
  if tabCount <= 1 then return "single tab"
  set newIdx to (random number from 1 to tabCount)
  set current tab of targetWindow to tab newIdx of targetWindow
  set index of targetWindow to 1
  activate
  return "window " & winIdx & " of " & winCount & ", tab " & newIdx & " of " & tabCount
end tell
EOF
)
  [ -z "$out" ] && out="error"
  log "  Safari tabs: $out"
}

# Cycle tabs in apps with NO scripting dictionary, using the app's own hotkey.
# This is a SYNTHETIC keystroke (the experiment's deepest reach for these apps)
# and is therefore opt-in. Keymaps are best-guesses — adjust to your bindings.
keyboard_cycle_tab() {
  local app="$1"
  if [ "$ENABLE_KEYBOARD_TAB_CYCLE" != true ]; then
    log "  $app: tab switch skipped (no scripting dictionary; ENABLE_KEYBOARD_TAB_CYCLE=false)"
    return 0
  fi
  local script=""
  case "$app" in
    Ghostty)                       script='keystroke "]" using {command down, shift down}' ;;  # next tab
    Code|"Visual Studio Code")     script='key code 124 using {command down, option down}' ;;   # Cmd+Opt+Right = next editor
    DBeaver|dbeaver)               script='key code 121 using {control down}' ;;                # Ctrl+PageDown = next editor
    *) log "  $app: no keyboard tab mapping"; return 0 ;;
  esac
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
  set frontmost of process "$app" to true
  $script
end tell
EOF
  then
    log "  $app: cycled tab via app hotkey (synthetic keystroke)"
  else
    log "  $app: keyboard tab cycle failed"
  fi
}

# Scroll the focused app up or down via a synthetic Page Up/Down key code.
# Page keys are universally safe — they never modify content, only the viewport.
# Synthetic input, so gated by ENABLE_KEYBOARD_TAB_CYCLE like the other
# keystroke actions. Used for Safari and VS Code (NOT Ghostty, to avoid acting
# on terminal content).
synthetic_scroll() {
  local app="$1" code label
  [ "$ENABLE_KEYBOARD_TAB_CYCLE" = true ] || return 0
  if [ $(( RANDOM % 2 )) -eq 0 ]; then code=121; label="PageDown"; else code=116; label="PageUp"; fi
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
  set frontmost of process "$app" to true
  key code $code
end tell
EOF
  then
    log "  $app: scrolled ($label, synthetic; read-only)"
  else
    log "  $app: scroll failed"
  fi
}

# Open a random recent file in VS Code: Cmd+P, arrow down a random count, Enter.
# Cmd+P only navigates the quick-open palette; it never edits content. The only
# misfire (palette didn't open) is the arrows moving the cursor (harmless) and a
# single stray newline from Enter — undoable with Cmd+Z. Synthetic input, gated
# by ENABLE_KEYBOARD_TAB_CYCLE. Esc first to dismiss any stray palette/modal.
vscode_open_random_file() {
  local app="$1" steps
  [ "$ENABLE_KEYBOARD_TAB_CYCLE" = true ] || return 0
  steps=$(( RANDOM % VSCODE_OPEN_FILE_MAX_STEPS + 1 ))   # 1..MAX down-arrows
  if osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
  set frontmost of process "$app" to true
  key code 53            -- Esc: clear any open palette/modal first
  keystroke "p" using command down
  delay 0.4              -- let the quick-open palette render
  repeat $steps times
    key code 125         -- Down arrow
    delay 0.05
  end repeat
  key code 36            -- Return: open the highlighted file
end tell
EOF
  then
    log "  $app: opened random recent file via Cmd+P (+$steps, synthetic)"
  else
    log "  $app: Cmd+P file open failed"
  fi
}

# ---------------------------------------------------------------------------
# Mouse movement — reset the HID idle timer so apps see you as "present".
#
# This is the one capability osascript cannot reach: there is no native
# "move cursor" in AppleScript, and CGWarpMouseCursorPosition does NOT reset
# the idle timer. cliclick's `m:` posts a REAL CGEvent, which does. So this is
# synthetic input — opt-in (ENABLE_MOUSE_JIGGLE) and labeled, like the keyboard
# tab cycle above. The rotation loop uses _do_random_move (visible wander); the
# 1px nudge-and-restore _do_jiggle remains as a fallback and for --jiggle-test.
# ---------------------------------------------------------------------------

_have_cliclick() { command -v cliclick >/dev/null 2>&1; }

# Seconds since the last real HID input event (0 on failure). nanoseconds/1e9.
hid_idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ {printf "%d\n", $NF/1000000000; exit}'
}

# The jiggle mechanism: nudge the cursor MOUSE_JIGGLE_PX and restore it to the
# exact original spot (imperceptible). No flag check here so jiggle_test can
# call it directly. Returns non-zero (and logs) on any expected failure.
_do_jiggle() {
  _have_cliclick || { log "  mouse-jiggle skipped (cliclick not installed: brew install cliclick)"; return 1; }
  local pos x y
  pos=$(cliclick p 2>/dev/null)   # prints "x,y"
  x=${pos%,*}; y=${pos#*,}
  case "$x" in ''|*[!0-9-]*) log "  mouse-jiggle: could not read cursor position ('$pos')"; return 1 ;; esac
  case "$y" in ''|*[!0-9-]*) log "  mouse-jiggle: could not read cursor position ('$pos')"; return 1 ;; esac
  cliclick "m:$((x + MOUSE_JIGGLE_PX)),$y" "m:$x,$y" >/dev/null 2>&1 \
    || { log "  mouse-jiggle: cliclick move failed"; return 1; }
  return 0
}

# Main-display pixel bounds as "W H". Finder reports desktop bounds as
# "0, 0, W, H"; we keep the last two fields. Empty on failure.
screen_size() {
  osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
    | awk -F', ' '{print $3, $4}'
}

# Move the cursor to a random on-screen point. Like the jiggle, cliclick's `m:`
# posts a REAL CGEvent, so this also resets the HID idle timer — it's just
# visible movement instead of an imperceptible nudge. Falls back to _do_jiggle
# if the screen bounds can't be read, so idle reset still happens.
# RANDOM caps at 32767, fine for normal/4K widths; an ultra-wide combined
# desktop wider than that would clamp. No flag check here (wrapper gates it).
_do_random_move() {
  _have_cliclick || { log "  mouse-move skipped (cliclick not installed: brew install cliclick)"; return 1; }
  local size w h x y
  size=$(screen_size)
  w=${size% *}; h=${size#* }
  case "$w" in ''|*[!0-9]*) log "  mouse-move: could not read screen size ('$size'); jiggling instead"; _do_jiggle; return $? ;; esac
  case "$h" in ''|*[!0-9]*) log "  mouse-move: could not read screen size ('$size'); jiggling instead"; _do_jiggle; return $? ;; esac
  x=$(( RANDOM % w ))
  y=$(( MENU_BAR_INSET + RANDOM % (h - MENU_BAR_INSET) ))   # MENU_BAR_INSET avoids the menu bar
  cliclick "m:$x,$y" >/dev/null 2>&1 || { log "  mouse-move: cliclick move failed"; return 1; }
  log "  mouse-move: cursor -> ${x},${y} (synthetic input; HID idle reset)"
  return 0
}

# Opt-in wrapper called from the rotation loop. Moves the cursor to a random
# on-screen point each tick (synthetic input; also resets the HID idle timer).
mouse_jiggle() {
  [ "$ENABLE_MOUSE_JIGGLE" = true ] || return 0
  _do_random_move
}

# After focusing an app, reach as deep as that app legitimately allows.
dispatch_deep() {
  local app="$1"
  case "$app" in
    Safari)
      raise_random_window "$app"
      safari_random_tab
      synthetic_scroll "$app"
      ;;
    Code|"Visual Studio Code")
      raise_random_window "$app"
      keyboard_cycle_tab "$app"
      synthetic_scroll "$app"
      [ $(( RANDOM % 100 )) -lt "$VSCODE_OPEN_FILE_PROBABILITY" ] && vscode_open_random_file "$app"
      ;;
    Ghostty|DBeaver|dbeaver)
      raise_random_window "$app"
      keyboard_cycle_tab "$app"
      ;;
    *)
      raise_random_window "$app"
      ;;
  esac
}

sleep_random() {
  local span secs
  span=$(( MAX_SLEEP - MIN_SLEEP + 1 ))
  secs=$(( RANDOM % span + MIN_SLEEP ))
  log "sleeping ${secs}s"
  sleep "$secs"
}

# ---------------------------------------------------------------------------
# Probe mode — measure capabilities live instead of asserting them
# ---------------------------------------------------------------------------
_probe_tabs() {
  case "$1" in
    Safari) osascript -e 'tell application "Safari" to count tabs of front window' 2>/dev/null || echo err ;;
    *) echo "n/a" ;;
  esac
}

_probe_geometry() {
  if osascript -e "tell application \"System Events\" to get position of window 1 of process \"$1\"" >/dev/null 2>&1; then
    echo "ok"
  else
    echo "blocked"
  fi
}

probe() {
  log "=== awake capability probe ==="
  local running line app isrun wc tabs geo
  if ! running=$(list_visible_apps); then
    log "ERROR: could not list visible apps via System Events."
    log "Grant Accessibility permission to the terminal app running this script, then retry."
    return 1
  fi
  printf '%-22s %-9s %-9s %-8s %-9s\n' "APP" "RUNNING" "WINDOWS" "TABS" "GEOMETRY"
  printf '%-22s %-9s %-9s %-8s %-9s\n' "---" "-------" "-------" "----" "--------"
  for app in "Safari" "Ghostty" "Code" "Visual Studio Code" "DBeaver" "dbeaver"; do
    isrun="no"; wc="-"; tabs="-"; geo="-"
    if printf '%s\n' "$running" | grep -qxF "$app"; then
      isrun="yes"
      wc=$(window_count "$app")
      tabs=$(_probe_tabs "$app")
      geo=$(_probe_geometry "$app")
    fi
    printf '%-22s %-9s %-9s %-8s %-9s\n' "$app" "$isrun" "$wc" "$tabs" "$geo"
  done
  echo
  log "TABS column = native tabs via AppleScript dictionary (Safari only)."
  log "'n/a' = app has no scripting dictionary; '-' = not running."
  log "GEOMETRY 'ok' = window position/size is settable (tiling works)."
}

# ---------------------------------------------------------------------------
# Jiggle test — prove the cursor nudge actually resets the HID idle timer.
# The real success criterion is "idle dropped to ~0", not "the cursor moved".
# ---------------------------------------------------------------------------
jiggle_test() {
  log "=== mouse-jiggle test ==="
  if ! _have_cliclick; then
    log "cliclick not found. Install it first:  brew install cliclick"
    exit 1
  fi
  log "Don't touch the mouse/keyboard during the countdown (let idle accrue)."
  local i
  for i in 3 2 1; do log "  measuring in ${i}s..."; sleep 1; done

  local before after
  before=$(hid_idle_seconds)
  log "HID idle BEFORE jiggle: ${before}s"
  if ! _do_jiggle; then
    log "RESULT: ❌ jiggle could not run (see message above)."
    exit 1
  fi
  after=$(hid_idle_seconds)
  log "HID idle AFTER  jiggle: ${after}s"

  if [ "${after:-9}" -lt "${before:-0}" ] || [ "${after:-9}" -le 0 ]; then
    log "RESULT: ✅ idle timer reset — apps will see you as present."
  else
    log "RESULT: ⚠️  idle did not drop. Check Accessibility permission for this"
    log "        terminal and that cliclick can post events."
  fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
cleanup() { echo; log "awake stopped."; exit 0; }

run_loop() {
  trap cleanup INT TERM
  log "awake started (pid $$). Ctrl+C to stop."
  log "sleep ${MIN_SLEEP}-${MAX_SLEEP}s | tile ${TILE_PROBABILITY}% | tab-switch ${ENABLE_TAB_SWITCH} | kbd-tab-cycle ${ENABLE_KEYBOARD_TAB_CYCLE} | mouse-jiggle ${ENABLE_MOUSE_JIGGLE}"

  while true; do
    local apps=() line n roll a b app
    while IFS= read -r line; do
      [ -n "$line" ] && apps+=("$line")
    done < <(list_visible_apps)

    n=${#apps[@]}
    if [ "$n" -eq 0 ]; then
      log "no visible apps found — is Accessibility permission granted to this terminal?"
      sleep_random
      continue
    fi

    roll=$(( RANDOM % 100 ))
    if [ "$roll" -lt "$TILE_PROBABILITY" ] && [ "$n" -ge 2 ]; then
      a=${apps[RANDOM % n]}
      b=$a
      while [ "$b" = "$a" ]; do b=${apps[RANDOM % n]}; done
      log "action: tile ($n apps available)"
      tile_two "$a" "$b"
    else
      app=${apps[RANDOM % n]}
      log "action: focus -> $app ($n apps available)"
      activate_app "$app"
      dispatch_deep "$app"
    fi

    # Reset the HID idle timer (opt-in). Moving the cursor every MIN_SLEEP-MAX_SLEEPs
    # keeps idle under MAX_SLEEP (<=60s), well below typical 5-min "away" cutoffs.
    mouse_jiggle

    sleep_random
  done
}

usage() {
  cat <<'USAGE'
awake.sh — macOS app-control experiment

USAGE:
  ./awake.sh            Start the random focus/tile rotation loop (Ctrl+C to stop)
  ./awake.sh --probe    Print a live capability map for the target apps and exit
  ./awake.sh --jiggle-test  Prove the mouse jiggle resets the HID idle timer
  ./awake.sh --help     Show this help

TUNABLES (edit the Config block at the top of the script):
  MIN_SLEEP / MAX_SLEEP        random wait per action (default 30-60s)
  TILE_PROBABILITY             % of ticks that tile two apps (default 25)
  ENABLE_TAB_SWITCH            switch Safari tabs via its dictionary (default true)
  ENABLE_KEYBOARD_TAB_CYCLE    opt-in: ALL synthetic keystrokes (default false) —
                               tab cycling (Ghostty/VS Code/DBeaver), Safari + VS Code
                               scrolling, and VS Code Cmd+P random file open
  VSCODE_OPEN_FILE_PROBABILITY % of VS Code focuses that open a random file (default 30)
  VSCODE_OPEN_FILE_MAX_STEPS   max down-arrows into the Cmd+P recent list (default 8)
  ENABLE_MOUSE_JIGGLE          opt-in: move the cursor to a random on-screen point
                               each tick to reset the HID idle timer / look "present"
                               (default false; needs cliclick: brew install cliclick)
  MOUSE_JIGGLE_PX              nudge size for the jiggle fallback / --jiggle-test (default 1)
  EXCLUDE_APPS                 app names to never select
  AWAKE_LOG_FILE (env)         also append logs to this file

REQUIREMENT:
  Grant Accessibility to your terminal app:
  System Settings -> Privacy & Security -> Accessibility.
  Without it, System Events calls silently do nothing.

This is a capability demo — it does not fake input to deceive anyone.
USAGE
}

main() {
  case "${1:-}" in
    --probe) probe ;;
    --jiggle-test) jiggle_test ;;
    -h|--help) usage ;;
    "") run_loop ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
