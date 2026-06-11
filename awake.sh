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
ENABLE_KEYBOARD_TAB_CYCLE="${ENABLE_KEYBOARD_TAB_CYCLE:-false}"  # opt-in: synthetic app-hotkey tab cycling (Ghostty/Code/DBeaver)
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

# After focusing an app, reach as deep as that app legitimately allows.
dispatch_deep() {
  local app="$1"
  case "$app" in
    Safari)
      raise_random_window "$app"
      safari_random_tab
      ;;
    Ghostty|Code|"Visual Studio Code"|DBeaver|dbeaver)
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
# Main loop
# ---------------------------------------------------------------------------
cleanup() { echo; log "awake stopped."; exit 0; }

run_loop() {
  trap cleanup INT TERM
  log "awake started (pid $$). Ctrl+C to stop."
  log "sleep ${MIN_SLEEP}-${MAX_SLEEP}s | tile ${TILE_PROBABILITY}% | tab-switch ${ENABLE_TAB_SWITCH} | kbd-tab-cycle ${ENABLE_KEYBOARD_TAB_CYCLE}"

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

    sleep_random
  done
}

usage() {
  cat <<'USAGE'
awake.sh — macOS app-control experiment

USAGE:
  ./awake.sh            Start the random focus/tile rotation loop (Ctrl+C to stop)
  ./awake.sh --probe    Print a live capability map for the target apps and exit
  ./awake.sh --help     Show this help

TUNABLES (edit the Config block at the top of the script):
  MIN_SLEEP / MAX_SLEEP        random wait per action (default 30-60s)
  TILE_PROBABILITY             % of ticks that tile two apps (default 25)
  ENABLE_TAB_SWITCH            switch Safari tabs via its dictionary (default true)
  ENABLE_KEYBOARD_TAB_CYCLE    opt-in synthetic-hotkey tab cycling for apps with
                               no dictionary, e.g. Ghostty/VS Code (default false)
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
    -h|--help) usage ;;
    "") run_loop ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
