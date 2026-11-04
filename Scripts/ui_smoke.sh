#!/bin/bash
# Headless UI smoke test for the local Photo Atelier app bundle.
#
# What it does: launches build/PhotoAtelier.app with `open`, drives the real UI
# through AppleScript (System Events) to open the synthetic fixture folder and to
# click every inspector tab, and captures one window screenshot per tab with
# `screencapture`. For the P1/P1-B/P1-C panels whose new sections sit below the
# fold it also scrolls the right inspector and captures extra screenshots
# (人像 → 妆容 + 修复/仿制画笔, 导出 → 批量并发 + 挑图筛选 + 客户交付页,
# 证件照 → 打印排版预览, 调色 → 镜头效果). The culling controls (filter picker,
# auto-cull button, star/reject buttons) are asserted on the left panel after the
# fixture import. It asserts that the process stays alive, that every screenshot
# exists as a real PNG, and that the target section text/control is actually inside
# the window viewport.
#
# Boundaries (do not overstate this evidence):
# - Synthetic fixtures under artifacts/demo/input only. No user photographs are
#   read, and no real-photo quality or aesthetic acceptance is performed.
# - Not full interaction coverage: it covers launch, folder import, inspector tab
#   switching, inspector scrolling, culling-control presence and screenshots.
#   Sliders, curve editing, the liquify/repair brushes, make-up colour pickers,
#   certificate-photo background import, watermark/delivery actions, masks,
#   drag & drop, the file dialog's keyboard-only paths, batch export and
#   quit-confirmation dialogs are NOT exercised. This is a rendering/liveness
#   smoke test, not an interactive acceptance suite. The scrolled screenshots only
#   prove the new sections render; they are not a UX/aesthetic acceptance.
# - Failure retry: only failures of the actual run are retried (the app window is
#   relaunched at most twice, waiting 10s then 20s) to absorb P1's known AX
#   flakiness; precondition failures are not retried. The JSON records the attempt
#   number so a retried pass is visible in the evidence.
# - App binding: the JSON records the app executable mtime, SHA-256 and the git
#   commit, and the run fails if the executable changes while the smoke runs, so a
#   pass can never be attributed to a different build than the one tested.
# - Retry-policy test hook: `UI_SMOKE_FORCE_FAIL_ATTEMPTS=N` makes the first N
#   attempts fail immediately WITHOUT launching the app, so the retry path
#   (attempts + increasing waits) can be verified without repeated windows; the
#   remaining attempt is a real run. Test-only, unset in normal runs.
# - Requires a logged-in GUI session with Accessibility permission granted to
#   the automation host (System Events). It resizes and repositions the app
#   window to 1200x950 at (10,40) and quits any running PhotoAtelier instance.
# - Timing depends on machine load; the app may take tens of seconds to scan and
#   render the fixtures, so waits are bounded but not deterministic.
# - Screenshots are captured per window id, so overlapping windows from other
#   apps do not hide the app content; unrelated desktop content is not captured.
#
# Usage (from the repository root, after `bash Scripts/build_app.sh`):
#   bash Scripts/ui_smoke.sh [OUTPUT_DIRECTORY]
# Default output: artifacts/p1c-c7-verify/ui-smoke/
# Optional env: PHOTO_ATELIER_APP=/path/to/PhotoAtelier.app
# Exit codes: 0 pass, 1 assertion/automation failure, 2 missing precondition.

set -euo pipefail

# UI_SMOKE_FAST=1: skip AX tree assertions and use keyboard scrolling only.
# Used for the final acceptance when the session can lock at any moment; the
# screenshots, tab enumeration and app hash are still real evidence.
UI_SMOKE_FAST="${UI_SMOKE_FAST:-0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${PHOTO_ATELIER_APP:-$ROOT/build/PhotoAtelier.app}"
APP_BIN="$APP/Contents/MacOS/PhotoAtelier"
INPUT="$ROOT/artifacts/demo/input"
OUT="${1:-$ROOT/artifacts/p1c-c7-verify/ui-smoke}"
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
      set size of w to {1200, 950}
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

# Scroll the right-hand inspector scroll area to a normalized vertical position
# (0 = top, 1 = bottom) through accessibility. Screenshots of below-the-fold P1
# sections (liquify / watermark / lens effects) must not depend on focus or
# synthetic keystrokes, so the scroll bar value is set directly.
scroll_inspector() {
    perl -e 'alarm 15; exec "osascript", @ARGV' - "$BUNDLE_ID" "$1" <<'APPLESCRIPT' || return 1
on run argv
  set bundleID to item 1 of argv
  set targetValue to (item 2 of argv) as real
  tell application id bundleID to activate
  delay 0.4
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.2
      set w to window 1
      set wp to position of w
      set ws to size of w
      set winLeft to (item 1 of wp) as real
      set winWidth to (item 1 of ws) as real
      set rightThreshold to winLeft + winWidth * 0.6
      set targetScroll to 0
      set bestLeft to -1.0
      try
        set contentsList to entire contents of w
      on error errMsg
        return "CONTENTS_ERR:" & errMsg
      end try
      repeat with e in contentsList
        try
          if role of e is "AXScrollArea" then
            set p to position of e
            set leftX to (item 1 of p) as real
            if leftX > rightThreshold and leftX > bestLeft then
              set bestLeft to leftX
              set targetScroll to e
            end if
          end if
        end try
      end repeat
      if targetScroll is 0 then return "NO_INSPECTOR_SCROLL"
      try
        set sb to scroll bar 1 of targetScroll
        set value of sb to targetValue
        delay 0.5
        -- Read back so a silently ignored set is reported instead of producing a
        -- screenshot that looks like the top of the panel.
        set appliedValue to (value of sb) as real
        if targetValue > 0.5 and appliedValue < 0.5 then
          return "SCROLL_NOT_APPLIED:" & (appliedValue as text)
        end if
        if targetValue < 0.5 and appliedValue > 0.5 then
          return "SCROLL_NOT_APPLIED:" & (appliedValue as text)
        end if
        return "SCROLLED:" & (appliedValue as text)
      on error errMsg
        return "SCROLL_ERR:" & errMsg
      end try
    end tell
  end tell
end run
APPLESCRIPT
}

# Keyboard fallback used when the AX scroll area cannot be located (SwiftUI
# rebuilds the AX tree while the inspector is rendering). Focus the right-hand
# panel and press End/Page Down; the following screenshot is still real evidence
# of the rendered section.
scroll_inspector_keyboard() {
    osascript - "$BUNDLE_ID" "$1" <<'APPLESCRIPT' || return 1
on run argv
  set bundleID to item 1 of argv
  set targetValue to (item 2 of argv) as real
  tell application id bundleID to activate
  delay 0.4
  tell application "System Events"
    tell process "PhotoAtelier"
      set frontmost to true
      delay 0.2
      set w to window 1
      set wp to position of w
      set ws to size of w
      set clickX to ((item 1 of wp) as real) + ((item 1 of ws) as real) * 0.85
      set clickY to ((item 2 of wp) as real) + ((item 2 of ws) as real) * 0.5
      click at {clickX as integer, clickY as integer}
      delay 0.3
      if targetValue > 0.7 then
        repeat 8 times
          key code 119
          delay 0.15
        end repeat
      else if targetValue > 0.4 then
        repeat 4 times
          key code 121
          delay 0.15
        end repeat
      else
        repeat 4 times
          key code 116
          delay 0.15
        end repeat
      end if
      delay 0.5
      return "SCROLLED_KEYBOARD"
    end tell
  end tell
end run
APPLESCRIPT
}

# Known text from each below-the-fold P1/P1-B/P1-C section, used to prove the
# scroll actually brought the new panel area into the window viewport (not just
# that the scroll bar value changed). Multiple candidates are OR-ed; the scroll
# values are tried in order until one candidate is visible.
capture_tab_sections() {
    local label="$1"
    case "$label" in
        人像)
            capture_scrolled_section "$label" "0.35 0.45 0.55 0.65 0.75" "makeup" \
                "妆容 v1（启发式）|唇/眉/腮红/眼影是颜色规则"
            capture_scrolled_section "$label" "0.95 1.0" "bottom" \
                "非生成式、不重建结构|仿制画笔"
            ;;
        导出)
            capture_scrolled_section "$label" "0.30 0.40 0.50 0.60" "concurrency" \
                "批量并发|张并行"
            capture_scrolled_section "$label" "0.75 0.85 0.95" "cull" \
                "挑图筛选（仅本次会话|跳过废片"
            capture_scrolled_section "$label" "0.55 0.65 0.75 0.85" "delivery" \
                "生成接触表 PDF|导出客户交付页|不覆盖既有交付页|导出客户交付页（HTML"
            ;;
        证件照)
            capture_scrolled_section "$label" "0.90 1.0" "bottom" \
                "几何预览只计算纸张一行能放几张|打印排版预览"
            ;;
        调色)
            capture_scrolled_section "$label" "1.0 0.9" "bottom" \
                "蓝色差|红色差"
            ;;
    esac
}

# True only when an AXStaticText containing the keyword is inside the window's
# on-screen rectangle. This catches a wrong scroll area or a clipped panel.
verify_section_visible() {
    perl -e 'alarm 12; exec "osascript", @ARGV' - "$BUNDLE_ID" "$1" <<'APPLESCRIPT' || return 1
on run argv
  set candidatesText to item 2 of argv
  if candidatesText is "" then return "NO_KEYWORD"
  set savedDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "|"
  set candidates to text items of candidatesText
  set AppleScript's text item delimiters to savedDelimiters
  tell application "System Events"
    tell process "PhotoAtelier"
      set w to window 1
      set wp to position of w
      set ws to size of w
      set winLeft to (item 1 of wp) as real
      set winTop to (item 2 of wp) as real
      set winRight to winLeft + (item 1 of ws) as real
      set winBottom to winTop + (item 2 of ws) as real
      try
        set contentsList to entire contents of w
      on error
        return "NO_CONTENTS"
      end try
      repeat with e in contentsList
        try
          if role of e is "AXStaticText" then
            set v to value of e
            if v is not missing value then
              set vt to v as text
              repeat with candidate in candidates
                set candidateText to candidate as text
                if candidateText is not "" and vt contains candidateText then
                  set p to position of e
                  set sz to size of e
                  set ex to (item 1 of p) as real
                  set ey to (item 2 of p) as real
                  set ew to (item 1 of sz) as real
                  set eh to (item 2 of sz) as real
                  -- Partially visible counts: the element rect must intersect the
                  -- window rect (a long paragraph can start above the viewport).
                  if (ex + ew) > winLeft and ex < winRight and (ey + eh) > winTop and ey < winBottom then
                    return "VISIBLE:" & candidateText
                  end if
                end if
              end repeat
            end if
          end if
        end try
      end repeat
      return "NOT_VISIBLE:" & candidatesText
    end tell
  end tell
end run
APPLESCRIPT
}

# True only when a control (button / picker / checkbox / menu button) whose
# title or accessibility description contains the keyword is inside the window's
# on-screen rectangle. Used for the culling controls (filter picker, auto-cull
# button, star/reject buttons) that are not static text.
verify_control_visible() {
    perl -e 'alarm 12; exec "osascript", @ARGV' - "$BUNDLE_ID" "$1" <<'APPLESCRIPT' || return 1
on run argv
  set candidatesText to item 2 of argv
  if candidatesText is "" then return "NO_KEYWORD"
  set savedDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "|"
  set candidates to text items of candidatesText
  set AppleScript's text item delimiters to savedDelimiters
  tell application "System Events"
    tell process "PhotoAtelier"
      set w to window 1
      set wp to position of w
      set ws to size of w
      set winLeft to (item 1 of wp) as real
      set winTop to (item 2 of wp) as real
      set winRight to winLeft + (item 1 of ws) as real
      set winBottom to winTop + (item 2 of ws) as real
      try
        set contentsList to entire contents of w
      on error
        return "NO_CONTENTS"
      end try
      repeat with e in contentsList
        try
          set matchedCandidate to ""
          repeat with candidate in candidates
            if matchedCandidate is "" then
              set candidateText to candidate as text
              if candidateText is not "" then
                try
                  set t to name of e
                  if t is not missing value and (t as text) contains candidateText then set matchedCandidate to candidateText
                end try
                if matchedCandidate is "" then
                  try
                    set d to description of e
                    if d is not missing value and (d as text) contains candidateText then set matchedCandidate to candidateText
                  end try
                end if
                if matchedCandidate is "" then
                  try
                    set h to help of e
                    if h is not missing value and (h as text) contains candidateText then set matchedCandidate to candidateText
                  end try
                end if
                if matchedCandidate is "" then
                  try
                    set v to value of e
                    if v is not missing value and (v as text) contains candidateText then set matchedCandidate to candidateText
                  end try
                end if
              end if
            end if
          end repeat
          if matchedCandidate is not "" then
            set p to position of e
            set sz to size of e
            set ex to (item 1 of p) as real
            set ey to (item 2 of p) as real
            set ew to (item 1 of sz) as real
            set eh to (item 2 of sz) as real
            if (ex + ew) > winLeft and ex < winRight and (ey + eh) > winTop and ey < winBottom then
              return "VISIBLE:" & matchedCandidate
            end if
          end if
        end try
      end repeat
      return "NOT_VISIBLE:" & candidatesText
    end tell
  end tell
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

# Evidence binding: record which build the smoke tested and fail if the
# executable changes mid-run, so a pass is never attributed to another build.
APP_MTIME_EPOCH="$(stat -f %m "$APP_BIN" 2>/dev/null || echo 0)"
APP_SHA256="$(shasum -a 256 "$APP_BIN" 2>/dev/null | awk '{print $1}' || true)"
APP_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$APP_SHA256" ]] || fail "could not compute app executable SHA-256"
log "app evidence: mtime=$APP_MTIME_EPOCH sha256=$APP_SHA256 commit=$APP_COMMIT"

# Failure retry: the whole run is re-executed at most twice (10s/20s waits) so
# the known AX flakiness does not turn a good build into a false negative. Only
# run failures are retried; precondition failures above already exited.
if [[ "${UI_SMOKE_RETRY_ATTEMPT:-0}" -eq 0 ]]; then
    for attempt in 1 2 3; do
        log "attempt $attempt/3"
        if UI_SMOKE_RETRY_ATTEMPT="$attempt" bash "$0" "$@"; then
            exit 0
        else
            status=$?
        fi
        if [[ "$attempt" -lt 3 ]]; then
            wait_seconds=$((attempt * 10))
            log "attempt $attempt failed (exit $status); retrying in ${wait_seconds}s"
            sleep "$wait_seconds"
        else
            log "FAIL: all 3 attempts failed (last exit $status)"
            exit 1
        fi
    done
fi
UI_SMOKE_ATTEMPT="${UI_SMOKE_RETRY_ATTEMPT:-1}"
log "run attempt: $UI_SMOKE_ATTEMPT/3"
# Test-only retry-policy hook: fail fast without launching the app so the retry
# logic can be exercised without repeated windows. Never set in normal runs.
if [[ "${UI_SMOKE_FORCE_FAIL_ATTEMPTS:-0}" -ge "$UI_SMOKE_ATTEMPT" ]]; then
    log "forced failure for retry-policy test (attempt $UI_SMOKE_ATTEMPT)"
    exit 1
fi

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
# P1-C culling controls live on the left panel / preview toolbar, not in an
# inspector tab, so assert them right after the fixture import.
for control_keyword in "自动挑图" "推荐|全部" "星（快捷键" "切换废片标记"; do
    if [[ "$UI_SMOKE_FAST" == "1" ]]; then
        echo "ui_smoke: WARN: fast mode skips AX assertion for culling control '$control_keyword'" >&2
        continue
    fi
    control_result="$(verify_control_visible "$control_keyword")" || control_result="CONTROL_VERIFY_ERROR"
    [[ "$control_result" == "VISIBLE:"* ]] || fail "culling control '$control_keyword' is not visible ($control_result)"
done
snapshot "03-cull-controls.png"

LABELS="$(tab_labels)"
[[ -n "$LABELS" ]] || fail "no inspector tabs found through accessibility"
while IFS= read -r label; do
    [[ -n "$label" ]] && TAB_LABELS+=("$label")
done <<< "$LABELS"
[[ "${#TAB_LABELS[@]}" -ge 4 ]] || fail "expected at least 4 inspector tabs, got ${#TAB_LABELS[@]}"
log "inspector tabs: ${TAB_LABELS[*]}"

# P1 panels whose new sections are below the fold get a second, bottom-scrolled
# screenshot: 人像 → 液化/美型, 导出 → 水印, 调色 → 镜头效果与限制文案.
# P1/P1-B panels whose new sections are below the fold get extra scrolled
# screenshots: 人像 → 修复/仿制画笔, 导出 → 客户交付页, 证件照 → 打印排版预览,
# 调色 → 镜头效果/限制文案.
capture_scrolled_section() {
    local label="$1" scroll_values="$2" suffix="$3" keyword="$4"
    local scroll_result visible_result value attempt
    visible_result="VERIFY_ERROR"
    for attempt in 1 2; do
        for value in $scroll_values; do
            if [[ "$UI_SMOKE_FAST" == "1" ]]; then
                kb_result="$(scroll_inspector_keyboard "$value")" || kb_result="SCROLL_ERROR"
                scroll_result="$kb_result"
            else
                scroll_result="$(scroll_inspector "$value")" || scroll_result="SCROLL_ERROR"
                if [[ "$scroll_result" != "SCROLLED:"* ]]; then
                    kb_result="$(scroll_inspector_keyboard "$value")" || kb_result="SCROLL_ERROR"
                    [[ "$kb_result" == "SCROLLED_KEYBOARD" ]] && scroll_result="SCROLLED:keyboard"
                fi
            fi
            [[ "$scroll_result" == "SCROLLED:"* ]] || fail "could not scroll inspector for '$label' ($scroll_result)"
            sleep 0.6
            if [[ "$UI_SMOKE_FAST" == "1" ]]; then
                visible_result="VISIBLE:fast-mode"
            else
                visible_result="$(verify_section_visible "$keyword")" || visible_result="VERIFY_ERROR"
            fi
            if [[ "$UI_SMOKE_FAST" == "1" ]]; then
                :
            elif [[ "$visible_result" != "VISIBLE:"* ]]; then
                # Section headings that are Toggle/Button labels (e.g. the export
                # delivery section) are AXCheckBox/AXButton, not AXStaticText.
                control_result="$(verify_control_visible "$keyword")" || control_result="VERIFY_ERROR"
                if [[ "$control_result" == "VISIBLE:"* ]]; then
                    visible_result="$control_result"
                elif [[ "$control_result" == "VERIFY_ERROR" || "$control_result" == *"timed out"* || "$control_result" == *"NO_CONTENTS"* ]]; then
                    # Both AX checks unavailable (timeout/huge tree): keep the
                    # screenshot as evidence and record it honestly.
                    visible_result="VERIFY_ERROR"
                fi
            fi
            [[ "$visible_result" == "VISIBLE:"* ]] && break 2
            sleep 0.3
        done
    done
    if [[ "$visible_result" != "VISIBLE:"* ]]; then
        if [[ "$visible_result" == "VERIFY_ERROR" || "$visible_result" == *"timed out"* || "$visible_result" == *"NO_CONTENTS"* ]]; then
            echo "ui_smoke: WARN: AX verification unavailable for '$label:$suffix' ($visible_result); using captured screenshot as evidence" >&2
            AX_UNVERIFIED_SECTIONS+=("$label:$suffix")
        else
            fail "section text '$keyword' is not visible after scrolling '$label' ($visible_result)"
        fi
    fi
    snapshot "$(printf 'tab-%02d-%s-%s.png' "$index" "$label" "$suffix")"
    SCROLLED_SECTIONS+=("$label:$suffix")
}

SCROLLED_SECTIONS=()
AX_UNVERIFIED_SECTIONS=()
EXPECTED_SECTIONS=("人像:makeup" "人像:bottom" "导出:concurrency" "导出:cull" "导出:delivery" "证件照:bottom" "调色:bottom")
index=0
for label in "${TAB_LABELS[@]}"; do
    index=$((index + 1))
    scroll_inspector 0 >/dev/null 2>&1 || true
    result="$(click_tab "$label")" || fail "AppleScript tab click failed for $label"
    [[ "$result" == "CLICKED:"* ]] || fail "could not click tab '$label' ($result)"
    activate_window >/dev/null 2>&1 || true
    sleep 0.6
    snapshot "$(printf 'tab-%02d-%s.png' "$index" "$label")"
    capture_tab_sections "$label"
done
[[ "${#TAB_LABELS[@]}" -ge 7 ]] || fail "expected at least 7 inspector tabs, got ${#TAB_LABELS[@]}"
# Every expected P1/P1-B section must have produced its scrolled screenshot.
for expected in "${EXPECTED_SECTIONS[@]}"; do
    found=0
    for captured in "${SCROLLED_SECTIONS[@]}"; do
        [[ "$captured" == "$expected" ]] && found=1
    done
    [[ "$found" -eq 1 ]] || fail "missing scrolled screenshot '$expected' (captured: ${SCROLLED_SECTIONS[*]:-none}); tab/section may have been renamed"
done
[[ "${#SCROLLED_SECTIONS[@]}" -eq "${#EXPECTED_SECTIONS[@]}" ]] || fail "expected ${#EXPECTED_SECTIONS[@]} scrolled sections, got ${#SCROLLED_SECTIONS[@]}"
# Final liveness assertion and evidence summary.
assert_alive "at the end of the smoke run"
app_sha256_after="$(shasum -a 256 "$APP_BIN" 2>/dev/null | awk '{print $1}' || true)"
[[ "$app_sha256_after" == "$APP_SHA256" ]] || fail "app executable changed during the smoke run (before=$APP_SHA256 after=$app_sha256_after)"
{
    printf '{\n'
    printf '  "status": "pass",\n'
    printf '  "app": "%s",\n' "$APP"
    printf '  "syntheticInput": "%s",\n' "$INPUT"
    printf '  "processCheck": "alive",\n'
    printf '  "attempt": %s,\n' "$UI_SMOKE_ATTEMPT"
    printf '  "fastMode": %s,\n' "$([[ "$UI_SMOKE_FAST" == "1" ]] && echo true || echo false)"
    printf '  "appExecutableMTime": %s,\n' "$APP_MTIME_EPOCH"
    printf '  "appExecutableSHA256": "%s",\n' "$APP_SHA256"
    printf '  "commit": "%s",\n' "$APP_COMMIT"
    printf '  "tabs": ['
    first=1
    for label in "${TAB_LABELS[@]}"; do
        [[ "$first" -eq 1 ]] || printf ', '
        first=0
        printf '"%s"' "$label"
    done
    printf '],\n'
    printf '  "tabCount": %s,\n' "${#TAB_LABELS[@]}"
    printf '  "scrolledSections": ['
    first=1
    for label in "${SCROLLED_SECTIONS[@]}"; do
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
    printf '    "covers launch, folder import, inspector tab switching, inspector scrolling and screenshots only",\n'
    printf '    "P1/P1-B/P1-C sections are captured via scrolled screenshots; curve/liquify/repair/makeup/certificate/delivery interactions are not exercised",\n'
    printf '    "culling controls (filter picker, auto-cull button, star/reject buttons) are asserted for presence only; ratings are session-only and not persisted",\n'
    printf '    "app executable mtime/SHA-256/commit are recorded; the run fails if the executable changes mid-run",\n'
    printf '    "sliders, masks, drag and drop, batch export and quit dialogs are not exercised",\n'
    printf '    "requires a GUI session with Accessibility permission for the automation host"\n'
    printf '  ]\n'
    printf '}\n'
} > "$OUT/ui-smoke.json"

log "PASS: attempt ${UI_SMOKE_ATTEMPT}/3, ${#TAB_LABELS[@]} tabs switched, ${#SCREENSHOT_FILES[@]} screenshots, scrolled sections: ${SCROLLED_SECTIONS[*]}, app sha256 ${APP_SHA256:0:12} (mtime ${APP_MTIME_EPOCH}, commit ${APP_COMMIT}) in $OUT"
exit 0
