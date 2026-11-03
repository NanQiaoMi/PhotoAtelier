#!/bin/bash
# Headless UI smoke test for the local Photo Atelier app bundle.
#
# What it does: launches build/PhotoAtelier.app with `open`, drives the real UI
# through AppleScript (System Events) to open the synthetic fixture folder and to
# click every inspector tab, and captures one window screenshot per tab with
# `screencapture`. It asserts that the process stays alive and that every
# screenshot exists as a real PNG.
#
# Boundaries (do not overstate this evidence):
# - Synthetic fixtures under artifacts/demo/input only. No user photographs are
#   read, and no real-photo quality or aesthetic acceptance is performed.
# - Not full interaction coverage: it covers launch, folder import, inspector tab
#   switching and screenshots. Sliders, masks, drag & drop, the file dialog's
#   keyboard-only paths, batch export and quit-confirmation dialogs are NOT
#   exercised. This is a rendering/liveness smoke test, not an interactive
#   acceptance suite.
# - Requires a logged-in GUI session with Accessibility permission granted to
#   the automation host (System Events). It resizes and repositions the app
#   window to 1200x800 at (10,40) and quits any running PhotoAtelier instance.
# - Timing depends on machine load; the app may take tens of seconds to scan and
#   render the fixtures, so waits are bounded but not deterministic.
# - Screenshots are captured per window id, so overlapping windows from other
#   apps do not hide the app content; unrelated desktop content is not captured.
#
# Usage (from the repository root, after `bash Scripts/build_app.sh`):
#   bash Scripts/ui_smoke.sh [OUTPUT_DIRECTORY]
# Default output: artifacts/p0-20261103/ui-smoke/
# Optional env: PHOTO_ATELIER_APP=/path/to/PhotoAtelier.app
# Exit codes: 0 pass, 1 assertion/automation failure, 2 missing precondition.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${PHOTO_ATELIER_APP:-$ROOT/build/PhotoAtelier.app}"
INPUT="$ROOT/artifacts/demo/input"
OUT="${1:-$ROOT/artifacts/p0-20261103/ui-smoke}"
BUNDLE_ID="local.photoatelier.mac"
PROCESS_PATTERN="PhotoAtelier.app/Contents/MacOS/PhotoAtelier"

FAILED=0
TAB_LABELS=()
SCREENSHOT_FILES=()

log() { printf 'ui_smoke: %s\n' "$*"; }
fail() {
    printf 'ui_smoke: FAIL: %s\n' "$*" >&2
    FAILED=1
    exit 1
}

app_pid() { pgrep -f "$PROCESS_PATTERN" | head -1 || true; }

quit_app() {
    if [[ -z "$(app_pid)" ]]; then return 0; fi
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 24); do
        if [[ -z "$(app_pid)" ]]; then return 0; fi
        sleep 0.25
    done
    local pid
    pid="$(app_pid)"
    if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; sleep 1; fi
    pid="$(app_pid)"
    if [[ -n "$pid" ]]; then kill -KILL "$pid" 2>/dev/null || true; sleep 0.5; fi
    return 0
}
trap 'quit_app' EXIT

window_id() {
    osascript -l JavaScript <<'JXA'
ObjC.import('CoreGraphics');
const opts = $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements;
const arr = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(opts, $.kCGNullWindowID));
let best = 0, bestArea = 0;
for (let i = 0; i < arr.count; i++) {
  const d = ObjC.deepUnwrap(arr.objectAtIndex(i));
  const owner = String(d.kCGWindowOwnerName);
  if (owner.indexOf('光屿') < 0 && owner.indexOf('PhotoAtelier') < 0) continue;
  const b = ObjC.deepUnwrap(d.kCGWindowBounds) || {};
  // Ignore tooltips, menu extras and other small helper windows.
  if ((b.Width || 0) < 800 || (b.Height || 0) < 600) continue;
  const area = (b.Width || 0) * (b.Height || 0);
  if (area > bestArea) { bestArea = area; best = d.kCGWindowNumber; }
}
best ? String(best) : "";
JXA
}

assert_alive() {
    local pid
    pid="$(app_pid)"
    [[ -n "$pid" ]] || fail "PhotoAtelier process is not running ($*)"
}

snapshot() {
    local name="$1"
    assert_alive "before screenshot $name"
    local attempt id bytes width
    for attempt in 1 2 3 4 5 6; do
        # Activating the app also switches back to its Space if the user moved away.
        osascript -e "tell application id \"$BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
        sleep 0.5
        id="$(window_id)"
        if [[ -z "$id" ]]; then sleep 0.5; continue; fi
        screencapture -x -o -l "$id" "$OUT/$name" >/dev/null 2>&1 || { sleep 0.5; continue; }
        [[ -s "$OUT/$name" ]] || { sleep 0.5; continue; }
        bytes="$(stat -f%z "$OUT/$name")"
        width="$(sips -g pixelWidth "$OUT/$name" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
        if [[ "$bytes" -gt 5000 && -n "$width" && "$width" -ge 1000 ]]; then
            SCREENSHOT_FILES+=("$name:$bytes")
            log "screenshot $name (${bytes} bytes, width ${width})"
            return 0
        fi
        sleep 0.5
    done
    fail "could not capture a valid app-window screenshot for $name (last id=${id:-none} bytes=${bytes:-0} width=${width:-unknown})"
}

# Bring the app forward, normalise the window so screenshots are deterministic.
activate_window() {
    osascript - "$BUNDLE_ID" <<'APPLESCRIPT' || return 1
on run argv
  set bundleID to item 1 of argv
  tell application id bundleID to activate
  delay 0.6
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.3
      set w to window 1
      set position of w to {10, 40}
      set size of w to {1200, 800}
      delay 0.5
    end tell
  end tell
  return "activated"
end run
APPLESCRIPT
}

# Open the synthetic fixture folder through the real NSOpenPanel (Cmd+O,
# Cmd+Shift+G path entry, then the panel's default "打开文件夹" button).
open_fixture_folder() {
    osascript - "$BUNDLE_ID" "$INPUT" <<'APPLESCRIPT' || return 1
on run argv
  set bundleID to item 1 of argv
  set inputPath to item 2 of argv
  tell application id bundleID to activate
  delay 0.6
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.3
      keystroke "o" using command down
      delay 1.8
    end tell
  end tell
  set the clipboard to inputPath
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.2
      keystroke "g" using {command down, shift down}
      delay 1.2
      keystroke "v" using command down
      delay 0.5
      key code 36
      delay 2.2
      set w to window 1
      set hasSheet to false
      repeat with e in (UI elements of w)
        try
          if role of e is "AXSheet" then set hasSheet to true
        end try
      end repeat
      if hasSheet then
        key code 36
        delay 1.5
      end if
      -- Select every candidate file in the navigated folder. This is required by
      -- the mixed file+folder panel (Open is inert with no selection) and is
      -- harmless on a folder-only panel.
      keystroke "a" using command down
      delay 0.6
      key code 36
      delay 2.0
      -- Fallback for panels where Return is inert: click the localized default
      -- button, then the last button as a last resort (Cancel comes first).
      if (count of windows) > 1 then
        set w to window 1
        set clicked to false
        repeat with e in (UI elements of w)
          try
            if role of e is "AXButton" then
              set t to ""
              try
                set t to title of e
              end try
              if t is "导入" or t is "打开文件夹" or t is "打开" or t is "Open" then
                click e
                set clicked to true
                exit repeat
              end if
            end if
          end try
        end repeat
        delay 1.2
        if clicked is false and (count of windows) > 1 then
          set w to window 1
          set panelButtons to {}
          repeat with e in (UI elements of w)
            try
              if role of e is "AXButton" then set end of panelButtons to e
            end try
          end repeat
          if (count of panelButtons) > 0 then
            click (item -1 of panelButtons)
            delay 1.2
          end if
        end if
      end if
      if (count of windows) > 1 then return "PANEL_STILL_OPEN"
    end tell
  end tell
  return "folder-open-requested"
end run
APPLESCRIPT
}

# Poll the footer status text until the fixture folder has been imported.
wait_for_folder_load() {
    local budget="${1:-90}"
    local status=""
    for _ in $(seq 1 "$budget"); do
        status="$(osascript - "$BUNDLE_ID" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  tell application "System Events"
    tell process "PhotoAtelier"
      try
        set w to window 1
        set g to group 1 of w
        repeat with e in (UI elements of g)
          try
            if role of e is "AXStaticText" then
              set v to value of e
              if v is not missing value then
                if (v as text) contains "已载入" then return (v as text)
                if (v as text) contains "01_山谷合成测试图" then return "fixture-visible:" & (v as text)
              end if
            end if
          end try
        end repeat
      end try
    end tell
  end tell
  return ""
end run
APPLESCRIPT
)"
        # "已载入 …" is the footer status; a visible fixture filename in the
        # library is accepted too (the status text may be emitted before/after the
        # library rows depending on render order).
        if [[ "$status" == *"已载入"* || "$status" == fixture-visible:* ]]; then
            log "folder import status: $status"
            return 0
        fi
        assert_alive "while waiting for folder import"
        sleep 1
    done
    log "import wait timeout; windows: $(osascript -e 'tell application "System Events" to tell process "PhotoAtelier" to get name of every window' 2>&1 || true)"
    log "import wait timeout; last status: ${status:-<empty>}"
    return 1
}

# Return the inspector tab labels exposed as radio buttons, one per line.
tab_labels() {
    osascript - "$BUNDLE_ID" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  tell application "System Events"
    tell process "PhotoAtelier"
      try
        set w to window 1
        set g to group 1 of w
        set rg to 0
        repeat with e in (UI elements of g)
          try
            if role of e is "AXRadioGroup" then set rg to e
          end try
        end repeat
        if rg is 0 then return ""
        set out to {}
        repeat with rb in (radio buttons of rg)
          set d to ""
          try
            set d to description of rb
          end try
          if d is not missing value and d is not "" then set end of out to (d as text)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as string
      on error
        return ""
      end try
    end tell
  end tell
end run
APPLESCRIPT
}

click_tab() {
    osascript - "$BUNDLE_ID" "$1" <<'APPLESCRIPT' || return 1
on run argv
  set bundleID to item 1 of argv
  set tabName to item 2 of argv
  tell application id bundleID to activate
  delay 0.4
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.2
      set w to window 1
      set g to group 1 of w
      set rg to 0
      repeat with e in (UI elements of g)
        try
          if role of e is "AXRadioGroup" then set rg to e
        end try
      end repeat
      if rg is 0 then return "NO_RADIO_GROUP"
      repeat with rb in (radio buttons of rg)
        set d to ""
        try
          set d to description of rb
        end try
        if d is tabName then
          click rb
          delay 0.8
          return "CLICKED:" & tabName
        end if
      end repeat
      return "NOT_FOUND:" & tabName
    end tell
  end tell
end run
APPLESCRIPT
}

# Wait until the app's menu bar is populated; right after launch System Events
# can see the process before the SwiftUI menu exists.
# The import menu item was renamed from 「打开照片文件夹…」 to 「打开照片…」 when
# the panel became a mixed file+folder picker. Match by prefix instead of an exact
# title so the smoke keeps working across that rename and any future wording tweak.
open_menu_item_name() {
    osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "PhotoAtelier"
    try
      repeat with mi in menu items of menu 1 of menu bar item "File" of menu bar 1
        try
          set n to name of mi
          if n is not missing value and (n as text) contains "打开照片" then return (n as text)
        end try
      end repeat
    end try
    return ""
  end tell
end tell
APPLESCRIPT
}

wait_for_app_ready() {
    for _ in $(seq 1 60); do
        if [[ -n "$(open_menu_item_name)" ]]; then
            return 0
        fi
        assert_alive "while waiting for the app menu"
        sleep 0.5
    done
    return 1
}

# Open the fixture folder through the panel with accessibility actions only
# (focus-independent): click the File menu item, then the panel's default button.
# The panel is expected to open in the fixture folder because the script seeds
# NSNavLastRootDirectory before launch. On a mixed file+folder panel the button is
# inert with no selection, so select-all is used and the button pressed again.
ax_open_folder() {
    osascript - "$BUNDLE_ID" <<'APPLESCRIPT' || return 1
on run argv
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.4
      -- Resolve the import menu item by prefix: W1/W2 renamed it from
      -- 「打开照片文件夹…」 to 「打开照片…」 when the panel became mixed.
      set openMenuItem to 0
      try
        repeat with mi in menu items of menu 1 of menu bar item "File" of menu bar 1
          try
            set n to name of mi
            if n is not missing value and (n as text) contains "打开照片" then set openMenuItem to mi
          end try
        end repeat
      end try
      if openMenuItem is not 0 then
        click openMenuItem
      else
        keystroke "o" using command down
      end if
      -- Wait for the panel window, then for its default button to appear.
      set panelReady to false
      repeat 24 times
        if (count of windows) is 2 then set panelReady to true
        if panelReady then exit repeat
        delay 0.25
      end repeat
      if panelReady is false then return "NO_PANEL"
      set w to window 1
      set openButton to 0
      repeat 24 times
        repeat with e in (UI elements of w)
          try
            if role of e is "AXButton" then
              set t to ""
              try
                set t to title of e
              end try
              if t is "导入" or t is "打开文件夹" or t is "打开" or t is "Open" then set openButton to e
            end if
          end try
        end repeat
        if openButton is not 0 then exit repeat
        delay 0.25
      end repeat
      if openButton is 0 then return "NO_OPEN_BUTTON"
      click openButton
      delay 2.0
      if (count of windows) > 1 then
        -- Mixed file+folder panel: the default button is inert without a selection.
        set frontmost to true
        delay 0.2
        keystroke "a" using command down
        delay 0.6
        click openButton
        delay 2.0
      end if
      if (count of windows) > 1 then return "PANEL_STILL_OPEN"
    end tell
  end tell
  return "folder-open-requested"
end run
APPLESCRIPT
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
command -v osascript >/dev/null 2>&1 || { printf 'ui_smoke: FAIL: osascript not found\n' >&2; exit 2; }
command -v screencapture >/dev/null 2>&1 || { printf 'ui_smoke: FAIL: screencapture not found\n' >&2; exit 2; }
[[ -d "$APP" ]] || { printf 'ui_smoke: FAIL: app bundle not found: %s (run "bash Scripts/build_app.sh" first; this smoke script never builds)\n' "$APP" >&2; exit 2; }
[[ -x "$APP/Contents/MacOS/PhotoAtelier" ]] || { printf 'ui_smoke: FAIL: app executable missing in %s\n' "$APP" >&2; exit 2; }

# Synthetic fixtures only. Generate them with the project's own fixture script
# if the ignored artifacts/demo/input directory is missing.
if [[ ! -f "$INPUT/01_山谷合成测试图.png" ]]; then
    log "synthetic fixtures missing; generating with Scripts/make_demo.swift"
    mkdir -p "$INPUT"
    swift Scripts/make_demo.swift "$INPUT" --include-broken >/dev/null || fail "synthetic fixture generation failed"
fi
[[ -d "$INPUT" ]] || fail "synthetic input directory missing: $INPUT"

mkdir -p "$OUT"
log "app bundle: $APP"
log "synthetic input: $INPUT"
log "output: $OUT"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
quit_app
# Point the app's remembered open-panel directory at the synthetic fixture folder
# so the panel opens there without a path-entry keystroke. This only touches the
# app's own preferences (bundle id), never project files or user photos.
defaults write "$BUNDLE_ID" NSNavLastRootDirectory -string "$INPUT" 2>/dev/null || log "warning: could not seed NSNavLastRootDirectory"
log "launching app with open"
open "$APP" || fail "open failed for $APP"
for _ in $(seq 1 60); do
    if [[ -n "$(app_pid)" ]]; then break; fi
    sleep 0.5
done
assert_alive "after launch"
sleep 2
wait_for_app_ready || fail "app menu bar did not become available"
activate_window || fail "could not activate/position the app window"
snapshot "01-launch.png"

import_ok=0
for attempt in 1 2; do
    if [[ "$attempt" -eq 1 ]]; then
        open_result="$(ax_open_folder)" || open_result="AX_FLOW_ERROR"
    else
        open_result="$(open_fixture_folder)" || open_result="KEYSTROKE_FLOW_ERROR"
    fi
    if [[ "$open_result" != "folder-open-requested" ]]; then
        log "attempt $attempt: open panel did not close ($open_result); retrying"
        osascript -e 'tell application "System Events" to tell process "PhotoAtelier" to key code 53' >/dev/null 2>&1 || true
        sleep 1
        continue
    fi
    if wait_for_folder_load 45; then import_ok=1; break; fi
    log "attempt $attempt: fixture folder import did not finish; retrying the open flow"
    osascript -e 'tell application "System Events" to tell process "PhotoAtelier" to key code 53' >/dev/null 2>&1 || true
    sleep 1
done
if [[ "$import_ok" -ne 1 ]]; then
    snapshot "99-import-failure.png" >/dev/null 2>&1 || true
    log "diagnostic windows: $(osascript -e 'tell application "System Events" to tell process "PhotoAtelier" to get name of every window' 2>&1 || true)"
    fail "fixture folder did not finish importing after 2 attempts"
fi
activate_window || fail "could not re-activate app after import"
snapshot "02-folder-loaded.png"

LABELS="$(tab_labels)"
[[ -n "$LABELS" ]] || fail "no inspector tabs found through accessibility"
while IFS= read -r label; do
    [[ -n "$label" ]] && TAB_LABELS+=("$label")
done <<< "$LABELS"
[[ "${#TAB_LABELS[@]}" -ge 4 ]] || fail "expected at least 4 inspector tabs, got ${#TAB_LABELS[@]}"
log "inspector tabs: ${TAB_LABELS[*]}"

index=0
for label in "${TAB_LABELS[@]}"; do
    index=$((index + 1))
    result="$(click_tab "$label")" || fail "AppleScript tab click failed for $label"
    [[ "$result" == "CLICKED:"* ]] || fail "could not click tab '$label' ($result)"
    activate_window >/dev/null 2>&1 || true
    sleep 0.6
    snapshot "$(printf 'tab-%02d-%s.png' "$index" "$label")"
done

# Final liveness assertion and evidence summary.
assert_alive "at the end of the smoke run"
{
    printf '{\n'
    printf '  "status": "pass",\n'
    printf '  "app": "%s",\n' "$APP"
    printf '  "syntheticInput": "%s",\n' "$INPUT"
    printf '  "processCheck": "alive",\n'
    printf '  "tabs": ['
    first=1
    for label in "${TAB_LABELS[@]}"; do
        [[ "$first" -eq 1 ]] || printf ', '
        first=0
        printf '"%s"' "$label"
    done
    printf '],\n'
    printf '  "screenshots": ['
    first=1
    for entry in "${SCREENSHOT_FILES[@]}"; do
        [[ "$first" -eq 1 ]] || printf ', '
        first=0
        printf '{"file": "%s", "bytes": %s}' "${entry%%:*}" "${entry##*:}"
    done
    printf '],\n'
    printf '  "boundaries": [\n'
    printf '    "synthetic fixtures only; no real-photo quality or aesthetic acceptance",\n'
    printf '    "covers launch, folder import, inspector tab switching and screenshots only",\n'
    printf '    "sliders, masks, drag and drop, batch export and quit dialogs are not exercised",\n'
    printf '    "requires a GUI session with Accessibility permission for the automation host"\n'
    printf '  ]\n'
    printf '}\n'
} > "$OUT/ui-smoke.json"

log "PASS: ${#TAB_LABELS[@]} tabs switched, ${#SCREENSHOT_FILES[@]} screenshots in $OUT"
exit 0
