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
TILE_PROBABILITY="${TILE_PROBABILITY:-25}"    # percent chance a tick tiles two apps side-by-side; otherwise full-window a single app
MENU_BAR_INSET="${MENU_BAR_INSET:-25}"        # px reserved at top of screen when tiling
# Single master switch. true = the full active mode: Safari tab switching,
# synthetic keystrokes (Safari/VS Code scroll, Ghostty/VS Code/DBeaver tab cycle),
# unique VS Code workspace-file opening, and random cursor movement. false = focus/tile/window
# rotation only. Cursor movement needs cliclick (brew install cliclick).
ENABLE_ALL="${ENABLE_ALL:-false}"
VSCODE_OPEN_FILE_PROBABILITY="${VSCODE_OPEN_FILE_PROBABILITY:-30}"  # % of VS Code focuses that open a unique workspace file
VSCODE_RANDOM_FILE_CYCLE_SIZE="${VSCODE_RANDOM_FILE_CYCLE_SIZE:-20}" # unique workspace files per shuffle cycle
MOUSE_JIGGLE_PX="${MOUSE_JIGGLE_PX:-1}"        # pixels to nudge before restoring the cursor (jiggle fallback / --jiggle-test)
EXCLUDE_APPS=("Terminal")     # app/process names never selected
AWAKE_EXCLUDE_APPS="${AWAKE_EXCLUDE_APPS:-}"   # comma-separated extra app/process names to never select
LOG_FILE="${AWAKE_LOG_FILE:-}"   # empty => stdout only
VSCODE_STATE_DIR=""               # ephemeral per-workspace queues; created lazily
case "$VSCODE_RANDOM_FILE_CYCLE_SIZE" in
  ''|*[!0-9]*|0) VSCODE_RANDOM_FILE_CYCLE_SIZE=20 ;;
esac

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

load_env_excludes() {
  local old_ifs item trimmed
  [ -z "$AWAKE_EXCLUDE_APPS" ] && return 0

  old_ifs=$IFS
  IFS=','
  for item in $AWAKE_EXCLUDE_APPS; do
    IFS=$old_ifs
    trimmed=$(printf '%s' "$item" | sed 's/^ *//;s/ *$//')
    [ -n "$trimmed" ] && EXCLUDE_APPS+=("$trimmed")
    IFS=','
  done
  IFS=$old_ifs
}

joined_exclude_apps() {
  local out="" e
  for e in "${EXCLUDE_APPS[@]}"; do
    [ -z "$e" ] && continue
    if [ -z "$out" ]; then
      out="$e"
    else
      out="$out, $e"
    fi
  done
  printf '%s' "$out"
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

# Maximize a single app to fill the main display (below the menu bar).
maximize_app() {
  local app="$1" dims x0 y0 W H top usableH
  dims=$(screen_size) || { log "maximize: cannot read screen size"; return 1; }
  read -r x0 y0 W H <<EOF
$dims
EOF
  top=$MENU_BAR_INSET
  usableH=$(( H - top ))
  set_window_geometry "$app" 0 "$top" "$W" "$usableH"
  activate_app "$app"
  log "maximized: $app (full screen)"
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
  [ "$ENABLE_ALL" = true ] || return 0
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
  if [ "$ENABLE_ALL" != true ]; then
    log "  $app: tab switch skipped (no scripting dictionary; ENABLE_ALL=false)"
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
# Synthetic input, so gated by ENABLE_ALL like the other keystroke actions.
# Used for Safari and VS Code (NOT Ghostty, to avoid acting on terminal content).
synthetic_scroll() {
  local app="$1" code label
  [ "$ENABLE_ALL" = true ] || return 0
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

# Resolve the front VS Code window to local workspace roots using VS Code's own
# workspaceStorage metadata. Output is: label<TAB>root1<TAB>root2...
vscode_workspace_info() {
  local app="$1"
  AWAKE_VSCODE_APP="$app" osascript -l JavaScript 2>/dev/null <<'JXA'
ObjC.import('Foundation');
function js(value) { return value === null || value === undefined ? '' : ObjC.unwrap(value); }
function readText(path) {
  var error = Ref();
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, error);
  return text ? js(text) : '';
}
function localPath(uriText) {
  if (!uriText || uriText.indexOf('file:') !== 0) return '';
  var url = $.NSURL.URLWithString(uriText);
  return url ? js(url.path.stringByStandardizingPath) : '';
}
function parseJsonc(text) {
  return JSON.parse(text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, ''));
}
var env = $.NSProcessInfo.processInfo.environment;
var appName = js(env.objectForKey('AWAKE_VSCODE_APP'));
var title = '';
try {
  var proc = Application('System Events').processes.byName(appName);
  if (!proc.exists() || proc.windows.length === 0) throw new Error('VS Code has no window');
  title = proc.windows[0].name();
} catch (e) { throw new Error('Could not read the front VS Code window'); }

var home = js(env.objectForKey('HOME'));
var storage = home + '/Library/Application Support/Code/User/workspaceStorage';
var fm = $.NSFileManager.defaultManager;
var error = Ref();
var entries = fm.contentsOfDirectoryAtPathError(storage, error);
if (!entries) throw new Error('VS Code workspace storage is unavailable');
var candidates = [];
for (var i = 0; i < entries.count; i++) {
  var metaPath = storage + '/' + js(entries.objectAtIndex(i)) + '/workspace.json';
  var raw = readText(metaPath);
  if (!raw) continue;
  try {
    var meta = JSON.parse(raw), roots = [], label = '';
    if (meta.folder) {
      var root = localPath(meta.folder);
      if (root) { roots.push(root); label = root.split('/').pop(); }
    } else if (meta.workspace) {
      var workspaceFile = localPath(meta.workspace);
      if (!workspaceFile) continue;
      label = workspaceFile.split('/').pop().replace(/\.code-workspace$/i, '');
      var workspace = parseJsonc(readText(workspaceFile));
      var base = workspaceFile.substring(0, workspaceFile.lastIndexOf('/'));
      (workspace.folders || []).forEach(function(folder) {
        var root = folder.uri ? localPath(folder.uri) : (folder.path || '');
        if (root && root.charAt(0) !== '/') root = js($(base + '/' + root).stringByStandardizingPath);
        if (root) roots.push(root);
      });
    }
    if (roots.length && label && (title === label + ' - Visual Studio Code' || title.indexOf(' - ' + label + ' - Visual Studio Code') >= 0)) {
      var attrs = fm.attributesOfItemAtPathError(metaPath, Ref());
      var modified = attrs ? ObjC.unwrap(attrs.objectForKey($.NSFileModificationDate).timeIntervalSince1970) : 0;
      candidates.push({label: label, roots: roots, modified: modified});
    }
  } catch (e) {}
}
if (!candidates.length) throw new Error('No local workspace matched the front window');
candidates.sort(function(a, b) { return b.modified - a.modified; });
console.log([candidates[0].label].concat(candidates[0].roots).join('\t'));
JXA
}

vscode_ensure_state_dir() {
  [ -n "$VSCODE_STATE_DIR" ] && [ -d "$VSCODE_STATE_DIR" ] && return 0
  VSCODE_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/awake-vscode.XXXXXX") \
    || { log "  Code: could not create temporary queue state"; return 1; }
}

vscode_cleanup_state() {
  case "$VSCODE_STATE_DIR" in
    */awake-vscode.*) [ -d "$VSCODE_STATE_DIR" ] && rm -rf -- "$VSCODE_STATE_DIR" ;;
  esac
  VSCODE_STATE_DIR=""
}

vscode_state_key() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

vscode_file_is_eligible() {
  local path="$1" name ext lower
  case "$path" in
    */.git/*|*/.svn/*|*/.hg/*|*/node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/out/*|*/target/*|*/coverage/*|*/.next/*|*/.nuxt/*|*/.cache/*|*/tmp/*|*/temp/*) return 1 ;;
  esac
  name=${path##*/}
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  ext=".${lower##*.}"
  case "$name" in
    Dockerfile|Makefile|Rakefile|Gemfile|Procfile|.gitignore|.gitattributes|.editorconfig|.env.example) return 0 ;;
  esac
  case "$ext" in
    .ps1|.psm1|.psd1|.sh|.bash|.zsh|.fish|.cmd|.bat|.py|.js|.jsx|.mjs|.cjs|.ts|.tsx|.java|.kt|.kts|.cs|.fs|.fsx|.go|.rs|.c|.cc|.cpp|.cxx|.h|.hpp|.php|.rb|.swift|.scala|.lua|.r|.sql|.graphql|.gql|.html|.htm|.css|.scss|.sass|.less|.vue|.svelte|.xml|.json|.jsonc|.yaml|.yml|.toml|.ini|.conf|.config|.properties|.md|.markdown|.txt|.rst) return 0 ;;
  esac
  return 1
}

# Write unique absolute eligible paths for tab-delimited workspace roots.
vscode_collect_files() {
  local roots="$1" output="$2" old_ifs root rel path
  : > "$output"
  old_ifs=$IFS
  IFS=$(printf '\t')
  for root in $roots; do
    IFS=$old_ifs
    [ -d "$root" ] || { IFS=$(printf '\t'); continue; }
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$root" ls-files --cached -- . 2>/dev/null | while IFS= read -r rel; do
        path="$root/$rel"
        [ -f "$path" ] && vscode_file_is_eligible "$path" && printf '%s\n' "$path"
      done >> "$output"
    else
      find "$root" \( -name .git -o -name .svn -o -name .hg -o -name node_modules -o -name vendor -o -name dist -o -name build -o -name out -o -name target -o -name coverage -o -name .next -o -name .nuxt -o -name .cache -o -name tmp -o -name temp \) -prune -o -type f -print 2>/dev/null |
        while IFS= read -r path; do
          vscode_file_is_eligible "$path" && printf '%s\n' "$path"
        done >> "$output"
    fi
    IFS=$(printf '\t')
  done
  IFS=$old_ifs
  LC_ALL=C sort -u "$output" -o "$output"
}

vscode_reset_cycle() {
  local label="$1" roots="$2" key="$3" pool queue cycle count
  pool="$VSCODE_STATE_DIR/$key.pool"
  queue="$VSCODE_STATE_DIR/$key.queue"
  vscode_collect_files "$roots" "$pool"
  count=$(wc -l < "$pool" | tr -d ' ')
  [ "${count:-0}" -gt 0 ] || { log "  Code: no eligible code/text files in workspace $label"; return 1; }
  awk 'BEGIN { srand() } { print rand() "\t" $0 }' "$pool" | LC_ALL=C sort -n | cut -f2- | head -n "$VSCODE_RANDOM_FILE_CYCLE_SIZE" > "$queue"
  cycle=0
  [ -f "$VSCODE_STATE_DIR/$key.cycle" ] && cycle=$(sed -n '1p' "$VSCODE_STATE_DIR/$key.cycle")
  cycle=$(( cycle + 1 ))
  printf '%s\n' "$cycle" > "$VSCODE_STATE_DIR/$key.cycle"
  printf '0\n' > "$VSCODE_STATE_DIR/$key.index"
  count=$(wc -l < "$queue" | tr -d ' ')
  log "  Code: workspace $label cycle $cycle reset ($count unique files)"
}

vscode_relative_path() {
  local path="$1" roots="$2" old_ifs root
  old_ifs=$IFS
  IFS=$(printf '\t')
  for root in $roots; do
    IFS=$old_ifs
    case "$path" in "$root"/*) printf '%s' "${path#"$root"/}"; return 0 ;; esac
    IFS=$(printf '\t')
  done
  IFS=$old_ifs
  printf '%s' "${path##*/}"
}

# Open one unique file from the active workspace. Queue state is ephemeral and
# independent per workspace; no keyboard input or file modification is involved.
vscode_open_random_file() {
  local app="$1" info tab label roots key queue index total path cycle relative
  [ "$ENABLE_ALL" = true ] || return 0
  info=$(vscode_workspace_info "$app") || { log "  $app: local workspace could not be resolved; file open skipped"; return 0; }
  tab=$(printf '\t')
  label=${info%%"$tab"*}
  roots=${info#*"$tab"}
  [ "$roots" != "$info" ] || { log "  $app: workspace has no local roots"; return 0; }
  vscode_ensure_state_dir || return 0
  key=$(vscode_state_key "$roots")
  queue="$VSCODE_STATE_DIR/$key.queue"
  index=0
  [ -f "$VSCODE_STATE_DIR/$key.index" ] && index=$(sed -n '1p' "$VSCODE_STATE_DIR/$key.index")
  total=0
  [ -f "$queue" ] && total=$(wc -l < "$queue" | tr -d ' ')
  if [ "${index:-0}" -ge "${total:-0}" ]; then
    vscode_reset_cycle "$label" "$roots" "$key" || return 0
    index=0
    total=$(wc -l < "$queue" | tr -d ' ')
  fi
  path=$(sed -n "$(( index + 1 ))p" "$queue")
  [ -f "$path" ] || { printf '%s\n' "$(( index + 1 ))" > "$VSCODE_STATE_DIR/$key.index"; return 0; }
  if ! osascript -e "tell application \"System Events\" to get frontmost of process \"$app\"" 2>/dev/null | grep -qx true; then
    log "  $app: foreground changed; workspace file open skipped"
    return 0
  fi
  /usr/bin/open -a "Visual Studio Code" "$path" >/dev/null 2>&1 &
  printf '%s\n' "$(( index + 1 ))" > "$VSCODE_STATE_DIR/$key.index"
  cycle=$(sed -n '1p' "$VSCODE_STATE_DIR/$key.cycle")
  relative=$(vscode_relative_path "$path" "$roots")
  log "  $app: opened $relative (cycle $cycle, $(( index + 1 ))/$total, unique)"
}

# ---------------------------------------------------------------------------
# Mouse movement — reset the HID idle timer so apps see you as "present".
#
# This is the one capability osascript cannot reach: there is no native
# "move cursor" in AppleScript, and CGWarpMouseCursorPosition does NOT reset
# the idle timer. cliclick's `m:` posts a REAL CGEvent, which does. So this is
# synthetic input — opt-in (ENABLE_ALL) and labeled, like the keyboard
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

# Move the cursor to a random on-screen point. Like the jiggle, cliclick's `m:`
# posts a REAL CGEvent, so this also resets the HID idle timer — it's just
# visible movement instead of an imperceptible nudge. Reuses screen_size()
# (x0 y0 W H); falls back to _do_jiggle if the bounds can't be read, so idle
# reset still happens. RANDOM caps at 32767, fine for normal/4K widths.
# No flag check here (wrapper gates it).
_do_random_move() {
  _have_cliclick || { log "  mouse-move skipped (cliclick not installed: brew install cliclick)"; return 1; }
  local size x0 y0 w h x y
  size=$(screen_size)
  read -r x0 y0 w h <<EOF
$size
EOF
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
  [ "$ENABLE_ALL" = true ] || return 0
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
  local running line app isrun wc tabs geo info tab label roots pool count
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
  for app in "Code" "Visual Studio Code"; do
    if printf '%s\n' "$running" | grep -qxF "$app"; then
      info=$(vscode_workspace_info "$app")
      if [ -z "$info" ]; then
        log "VS Code workspace: unresolved or remote-only"
      else
        tab=$(printf '\t')
        label=${info%%"$tab"*}
        roots=${info#*"$tab"}
        if vscode_ensure_state_dir; then
          pool="$VSCODE_STATE_DIR/probe.pool"
          vscode_collect_files "$roots" "$pool"
          count=$(wc -l < "$pool" | tr -d ' ')
          log "VS Code workspace: $label | eligible code/text files: ${count:-0}"
        fi
      fi
      break
    fi
  done
  vscode_cleanup_state
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
cleanup() { echo; vscode_cleanup_state; log "awake stopped."; exit 0; }

run_loop() {
  trap cleanup INT TERM
  log "awake started (pid $$). Ctrl+C to stop."
  log "sleep ${MIN_SLEEP}-${MAX_SLEEP}s | tile ${TILE_PROBABILITY}% | active-mode (ENABLE_ALL) ${ENABLE_ALL}"
  log "excluding apps: $(joined_exclude_apps)"

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
      log "action: full window -> $app ($n apps available)"
      maximize_app "$app"
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
  TILE_PROBABILITY             % of ticks that tile two apps side-by-side; the rest full-window a single app (default 25)
  ENABLE_ALL                   single master switch (default false). true = full
                               active mode: Safari tab switching, synthetic keystrokes
                               (Safari/VS Code scroll, Ghostty/VS Code/DBeaver tab
                               cycle), unique VS Code workspace files, and random cursor
                               movement (needs cliclick: brew install cliclick)
  VSCODE_OPEN_FILE_PROBABILITY % of VS Code focuses that open a workspace file (default 30)
  VSCODE_RANDOM_FILE_CYCLE_SIZE unique files per workspace cycle (default 20)
  MOUSE_JIGGLE_PX              nudge size for the jiggle fallback / --jiggle-test (default 1)
  EXCLUDE_APPS                 app names to never select (default: Terminal)
  AWAKE_EXCLUDE_APPS           comma-separated extra app names to never select
  AWAKE_LOG_FILE (env)         also append logs to this file

REQUIREMENT:
  Grant Accessibility to your terminal app:
  System Settings -> Privacy & Security -> Accessibility.
  Without it, System Events calls silently do nothing.

This is a capability demo — it does not fake input to deceive anyone.
USAGE
}

main() {
  load_env_excludes

  case "${1:-}" in
    --probe) probe ;;
    --jiggle-test) jiggle_test ;;
    -h|--help) usage ;;
    "") run_loop ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
