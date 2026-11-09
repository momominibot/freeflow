#!/bin/bash
# FreeFlow smoke test: every function, one command.
#
#   scripts/smoke.sh            build, install, then everything
#   scripts/smoke.sh static     no app needed: build, units, tools, engine, AI, MCP, pictures of every page
#   scripts/smoke.sh live       the installed app: window, dictation, notes, meetings, transforms, files
#   SMOKE_NARROW=1 ...          also draws every page at the narrowest window (860)
#   SMOKE_QWEN=1 ...            also tries the optional Qwen3-ASR engine
#
# The live part drives the real app: it speaks through the speakers into the microphone (a natural local voice, Kokoro, see
# scripts/tools/speak.py; the robotic macOS `say` voice only if Kokoro is missing), types into a scratch
# TextEdit document and clicks the window through Accessibility. Nobody should type or touch the mouse while it runs, and the
# volume must be up. Your history, notes, dictionary, snippets and settings are saved first and put back at the end.
# Exit code 0 means green. macOS bash 3.2: no associative arrays, no GNU timeout.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
MODE=${1:-all}
BIN=$ROOT/build/FreeFlow.app/Contents/MacOS/FreeFlow
APP=/Applications/FreeFlow.app
APPBIN=$APP/Contents/MacOS/FreeFlow
SUP="$HOME/Library/Application Support/FreeFlow"
LOG="$HOME/Library/Logs/FreeFlow/freeflow.log"
DOM=com.momominibot.freeflow
WORK=$(mktemp -d /private/tmp/ff-smoke.XXXXXX)
PY=/opt/homebrew/bin/python3.14
[ -x "$PY" ] || PY=python3

pass=0; fail=0; skip=0; FAILED=""
ok()   { echo "ok    $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); FAILED="$FAILED
  - $1"; }
skp()  { echo "skip  $1"; skip=$((skip+1)); }
stage(){ echo; echo "== $1"; STAGE_T=$(date +%s); }
tmo()  { perl -e 'alarm shift; exec @ARGV' "$@"; }          # tmo SECONDS command...
# check "name" command...   passes when the command exits 0
check(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
# wait_for SECONDS command...   polls once a second
wait_for(){ local n=$1; shift; local i=0; while [ $i -lt "$n" ]; do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; i=$((i+1)); done; return 1; }

# ---------------------------------------------------------------- the voice used for every spoken test

# The voices FreeFlow keeps: assets/voices/voices.json (the list and samples) and the model in its data folder.
# speak.py finds the model by itself; KOKORO_DIR only overrides it. The Python needs kokoro_onnx: a FreeFlow one if it exists,
# otherwise the one from the older Lemo Opuscar project.
VOICE_PY=${FF_VOICE_PY:-}
if [ -z "$VOICE_PY" ]; then
  for c in "$SUP/engines/voice/venv/bin/python" "$HOME/Doubao/chats/2026-10-06/new-chat-10/lemo-opuscar/.venv/bin/python"; do [ -x "$c" ] && { VOICE_PY=$c; break; }; done
fi
VOICE_KIND=""
voice_lines() {   # name <TAB> voice(s) <TAB> text; " || " separates the speakers' turns
  cat <<'LINES'
dictation	warm	Hi Maria, the quarterly review is on Thursday at three. Could you send me the numbers before then?
tapmode	warm	Remember to book the venue for Friday evening.
snippet	warm	My test address.
note	warm	Note to self, call the dentist on Friday.
command	warm	Make this shorter.
meeting	warm,narrator	Okay, let us go through the launch plan. The website goes live on Thursday morning, and the invoice template still needs one more check. || I can do that today. Maria is sending the invoice to the shop team, and I will update the price list before the weekend. || Great. So the decision is that we launch on Thursday, Maria sends the invoice, and Daniel updates the website by Wednesday night. Anything else we need to settle? || No, that covers it. Thanks, everyone.
file	narrator	The new price list goes live on Monday. Please tell the shop team before the weekend, and send me the final numbers once they have been checked. Thanks very much for the help.
LINES
}
prepare_voice() {   # renders every line once; later calls do nothing
  [ -n "$VOICE_KIND" ] && return 0
  mkdir -p "$WORK/voice"
  voice_lines > "$WORK/voice/lines.tsv"
  if [ -n "$VOICE_PY" ] && "$VOICE_PY" scripts/tools/speak.py "$WORK/voice" < "$WORK/voice/lines.tsv" >"$WORK/voice/render.log" 2>&1; then
    VOICE_KIND=kokoro; ok "natural test voice rendered ($(grep -c 's,' "$WORK/voice/render.log") lines, Kokoro, two speakers for the meeting)"
  else
    VOICE_KIND=say; skp "Kokoro is not available (see scripts/tools/speak.py): the test speaks with the robotic macOS voice"
    local name voice text
    while IFS="$(printf '\t')" read -r name voice text; do
      [ -n "$name" ] && say -v Samantha -o "$WORK/voice/$name.aiff" "$(echo "$text" | sed 's/ || / /g')" >/dev/null 2>&1 && afconvert -f WAVE -d LEI16@24000 "$WORK/voice/$name.aiff" "$WORK/voice/$name.wav" >/dev/null 2>&1
    done < "$WORK/voice/lines.tsv"
  fi
}
play() { afplay "$WORK/voice/$1.wav" >/dev/null 2>&1; }       # blocks until the line has been spoken

# ---------------------------------------------------------------- static

stage_build() {
  stage "Build"
  if ./build.sh >"$WORK/build.log" 2>&1; then ok "build.sh builds, signs and runs its own checks"; else bad "build.sh (see $WORK/build.log)"; tail -5 "$WORK/build.log"; fi
  check "the built app is signed" codesign --verify "$ROOT/build/FreeFlow.app"
  check "Info.plist is valid" plutil -lint Info.plist
  local res="$ROOT/build/FreeFlow.app/Contents/Resources"
  check "fonts are bundled" test -f "$res/Fonts/Manrope-Medium.ttf" -a -f "$res/Fonts/Newsreader-SemiBold.ttf"
  check "logo and app icon are bundled" test -f "$res/Brand/logo-mark.png" -a -f "$res/AppIcon.icns"
  local want have
  want=$(ls assets/art/*.webp | wc -l | tr -d ' '); have=$(ls "$res"/Brand/art/*.webp 2>/dev/null | wc -l | tr -d ' ')
  [ "$want" = "$have" ] && ok "all $want painted pictures are bundled" || bad "painted pictures bundled: $have of $want"
  check "MCP server and Qwen engine scripts are bundled" test -x "$res/freeflow-mcp.py" -a -f "$res/qwen_server.py" -a -x "$res/install-qwen-engine.sh"
}

stage_units() {
  stage "Unit checks"
  "$BIN" --test >"$WORK/unit.log" 2>&1
  local rc=$? oks fails
  oks=$(grep -c '^ok' "$WORK/unit.log"); fails=$(grep -c '^FAIL' "$WORK/unit.log")
  if [ $rc -eq 0 ] && [ "$fails" = 0 ] && [ "$oks" -ge 150 ]; then ok "$oks unit checks pass (text, snippets, modes, meetings, scratchpad, insights, import, export, appearance)"
  else bad "unit checks: $oks ok, $fails failed, exit $rc"; grep '^FAIL' -A2 "$WORK/unit.log" | head -20; fi
}

stage_scripts() {
  stage "Scripts"
  local f
  for f in build.sh install.sh scripts/smoke.sh scripts/install-qwen-engine.sh; do [ -f "$f" ] && check "bash syntax: $f" bash -n "$f"; done
  for f in scripts/*.py scripts/art/*.py scripts/tools/*.py; do check "python syntax: $f" "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f"; done
  if tmo 60 python3 scripts/freeflow-mcp.py --selfcheck >"$WORK/mcp.log" 2>&1; then ok "MCP server selfcheck"; else bad "MCP server selfcheck"; tail -5 "$WORK/mcp.log"; fi
  grep -q workday_summary "$WORK/mcp.log" && ok "the MCP server offers the workday summary" || bad "workday_summary is not in the MCP tool list"
  if [ -x "$HOME/.local/bin/hermes" ] || [ -x "$HOME/.local/bin/fleet-bridge" ]; then ok "a Hermes hand-over (hermes or fleet-bridge) is installed and executable"; else bad "neither hermes nor fleet-bridge is installed"; fi
  check "compare-engines.py runs --help" tmo 20 python3 scripts/compare-engines.py --help
}

stage_voices() {
  stage "The natural voices FreeFlow keeps"
  local json=assets/voices/voices.json
  if ! "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['default'] in [v['id'] for v in d['voices']]; assert all(v.get('alias') and v.get('feel') for v in d['voices'])" "$json" 2>"$WORK/voices.err"; then bad "voices.json is valid, its default is one of its voices"; cat "$WORK/voices.err"; return; fi
  ok "voices.json is valid: $("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['voices']))" "$json") voices, default $("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['default'])" "$json")"
  local dir; dir=$("$PY" -c "import json,os,sys; print(os.path.expanduser(json.load(open(sys.argv[1]))['model_dir']))" "$json")
  if [ -s "$dir/kokoro-v1.0.onnx" ] && [ -s "$dir/voices-v1.0.bin" ] && [ "$(stat -f %z "$dir/kokoro-v1.0.onnx")" -gt 300000000 ]; then ok "the Kokoro model is stored in FreeFlow's data folder ($(du -sh "$dir" | cut -f1))"; else bad "the Kokoro model is missing from $dir"; fi
  local missing=""
  for id in $("$PY" -c "import json,sys; print(' '.join(v['id'] for v in json.load(open(sys.argv[1]))['voices']))" "$json"); do
    f=assets/voices/samples/$id.m4a
    dur=$(afinfo "$f" 2>/dev/null | awk '/estimated duration/ {print int($3)}')
    [ -n "$dur" ] && [ "$dur" -ge 3 ] && [ "$dur" -le 15 ] || missing="$missing $id"
  done
  [ -z "$missing" ] && ok "every kept voice has a playable sample in assets/voices/samples" || bad "samples missing or broken:$missing"
  if [ -n "$VOICE_PY" ] && "$VOICE_PY" scripts/tools/speak.py --voices >"$WORK/voices.list" 2>&1; then
    local gone=""
    for id in $("$PY" -c "import json,sys; print(' '.join(v['id'] for v in json.load(open(sys.argv[1]))['voices']))" "$json"); do grep -q "^$id " "$WORK/voices.list" || gone="$gone $id"; done
    [ -z "$gone" ] && ok "the stored model has every kept voice" || bad "the model has no voice:$gone"
  else bad "speak.py --voices failed (needs a Python with kokoro_onnx)"; fi
}

stage_system() {
  stage "System and engines"
  "$BIN" --status >"$WORK/status.log" 2>&1
  grep -q "microphone: authorized" "$WORK/status.log" && ok "microphone is allowed" || bad "microphone is not allowed ($(grep microphone "$WORK/status.log"))"
  grep -q "speech engine: /" "$WORK/status.log" && ok "whisper-server is installed" || bad "whisper-server is missing"
  grep -q "speech model: present" "$WORK/status.log" && ok "speech model is present" || bad "speech model is missing"
  grep -q ": ready" "$WORK/status.log" && ok "local AI (Ollama) is ready" || bad "local AI is not running (start Ollama)"
  if grep -q "accessibility (typing into apps): granted" "$WORK/status.log"; then ok "Accessibility is granted (typing into other apps)"; else bad "Accessibility is not granted to the terminal or app"; fi

  prepare_voice
  afconvert -f WAVE -d LEI16@16000 "$WORK/voice/dictation.wav" "$WORK/engine.wav" >/dev/null 2>&1
  if tmo 120 "$BIN" --selftest "$WORK/engine.wav" en >"$WORK/selftest.log" 2>&1 && grep -qi "thursday" "$WORK/selftest.log"; then
    ok "Whisper turns speech into text ($(grep SECONDS "$WORK/selftest.log" | sed 's/SECONDS (including model load): //')s)"
  else bad "Whisper selftest"; tail -4 "$WORK/selftest.log"; fi

  tmo 90 "$BIN" --test-ai "um so we should budget 50k actually 75k" formal >"$WORK/ai.log" 2>&1
  if grep -q "^AI:" "$WORK/ai.log" && grep -q "75" "$WORK/ai.log" && ! grep -qiE "^AI:.*\bum\b" "$WORK/ai.log"; then ok "AI tidy-up rewrites and keeps the number ($(grep '^AI:' "$WORK/ai.log" | cut -c1-60))"
  else bad "AI tidy-up"; cat "$WORK/ai.log" | head -4; fi

  tmo 30 "$BIN" --probe-meetings >"$WORK/probe.log" 2>&1
  grep -q "^supported:" "$WORK/probe.log" && ok "call detection runs (current call: $(grep 'current call' "$WORK/probe.log" | sed 's/current call: //'))" || bad "call detection probe"

  if [ "${SMOKE_QWEN:-0}" = 1 ]; then
    if [ -x "$SUP/engines/qwen/venv/bin/python" ]; then
      if tmo 300 "$BIN" --selftest "$WORK/engine.wav" en qwen >"$WORK/qwen.log" 2>&1 && grep -qi thursday "$WORK/qwen.log"; then ok "Qwen3-ASR turns speech into text"; else bad "Qwen3-ASR selftest"; fi
    else skp "Qwen3-ASR engine is not installed"; fi
  fi
}

stage_render() {
  stage "Every page, drawn light and dark"
  rm -rf "$WORK/ui"; mkdir -p "$WORK/ui"
  if tmo 400 "$BIN" --render-ui "$WORK/ui" >"$WORK/render.log" 2>&1; then ok "--render-ui finishes"; else bad "--render-ui"; fi
  local light dark
  light=$(ls "$WORK/ui"/*.png 2>/dev/null | wc -l | tr -d ' '); dark=$(ls "$WORK/ui/dark"/*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$light" -ge 23 ] && [ "$light" = "$dark" ] && ok "$light light and $dark dark pictures (10 pages, 7 settings tabs, 6 bar states)" || bad "pictures: $light light, $dark dark"
  if "$PY" -c "import PIL" 2>/dev/null; then
    "$PY" - "$WORK/ui" <<'EOF' >"$WORK/pix.log" 2>&1
import sys, glob, os
from PIL import Image, ImageStat
d = sys.argv[1]; bad = []
for f in sorted(glob.glob(d + "/page-*.png") + glob.glob(d + "/settings-*.png")):
    l = ImageStat.Stat(Image.open(f).convert("L")).mean[0]
    k = ImageStat.Stat(Image.open(os.path.join(d, "dark", os.path.basename(f))).convert("L")).mean[0]
    if not (l > 170): bad.append(f"{os.path.basename(f)} light is {l:.0f}")
    if not (k < 90): bad.append(f"{os.path.basename(f)} dark is {k:.0f}")
for f in sorted(glob.glob(d + "/pill-*.png")):
    if os.path.getsize(f) < 20000: bad.append(os.path.basename(f) + " looks empty")
print("\n".join(bad) if bad else "fine")
sys.exit(1 if bad else 0)
EOF
    if [ $? -eq 0 ]; then ok "light pages are pale, dark pages are deep purple, every bar state is drawn"; else bad "picture brightness"; cat "$WORK/pix.log"; fi
  else skp "Pillow is missing, skipped the brightness check"; fi
  if [ "${SMOKE_NARROW:-0}" = 1 ]; then
    rm -rf "$WORK/ui860"; mkdir -p "$WORK/ui860"
    if FF_SHOT_WIDTH=860 tmo 400 "$BIN" --render-ui "$WORK/ui860" >/dev/null 2>&1; then ok "pages draw at 860 wide (see $WORK/ui860)"; else bad "narrow render"; fi
  fi
}

# ---------------------------------------------------------------- live

AX=""; SAY_OK=1; TE_NAMES=""
post()  { "$APPBIN" --debug-post "$1"; }
loglen(){ wc -l < "$LOG" | tr -d ' '; }
logsince(){ tail -n +$(( $1 + 1 )) "$LOG"; }
logsaw(){ logsince "$1" | grep -qF -- "$2"; }               # logsaw OFFSET text
count_files(){ ls "$1" 2>/dev/null | wc -l | tr -d ' '; }
newest(){ ls -t "$1" 2>/dev/null | head -1; }

te_new() {   # a fresh empty TextEdit document in front, remembered so only ours are closed
  local name
  name=$(osascript <<'EOF'
tell application "TextEdit"
  activate
  make new document
  return name of front document
end tell
EOF
)
  TE_NAMES="$TE_NAMES|$name"
  sleep 0.6
}
te_text() { osascript -e 'tell application "TextEdit" to get text of front document' 2>/dev/null; }
te_set()  { osascript - "$1" <<'EOF'
on run argv
  tell application "TextEdit"
    activate
    set text of front document to item 1 of argv
  end tell
  tell application "System Events" to keystroke "a" using command down
end run
EOF
}
te_has()  { te_text | grep -qi -- "$1"; }
te_close_ours() {   # only the unsaved documents this run made, matched by their exact names
  osascript - "$TE_NAMES|" <<'EOF' >/dev/null 2>&1
on run argv
  set names to item 1 of argv
  tell application "TextEdit"
    repeat with d in (documents as list)
      try
        if names contains ("|" & (name of d) & "|") then close d saving no
      end try
    end repeat
  end tell
end run
EOF
}

# Keystrokes only go out while TextEdit is verified to be in front: never into whatever else happens to hold the focus.
te_front() { local i=0; while [ $i -lt 24 ]; do osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1; [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = TextEdit ] && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
tp() { te_front || return 1; osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1; }
bk() { te_front || return 1; osascript -e 'tell application "System Events"' -e "repeat $1 times" -e 'key code 51' -e 'end repeat' -e 'end tell' >/dev/null 2>&1; }
nl() { te_front || return 1; osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1; }

relaunch_app() {   # relaunch_app [launch arguments for FreeFlow...]
  pkill -x FreeFlow >/dev/null 2>&1; sleep 1; pkill -9 -x FreeFlow >/dev/null 2>&1; sleep 0.5
  if [ $# -gt 0 ]; then open "$APP" --args "$@"; else open "$APP"; fi
  wait_for 40 pgrep -x FreeFlow
  # the speech engine is up when its port answers
  wait_for 90 sh -c 'curl -s -o /dev/null http://127.0.0.1:8178/'
  sleep 3
}

snapshot_data() {
  mkdir -p "$WORK/data"
  local f
  for f in dictionary.txt learned.txt snippets.txt styles.txt modes.json history.jsonl history.txt; do
    if [ -f "$SUP/$f" ]; then cp -p "$SUP/$f" "$WORK/data/$f"; else touch "$WORK/data/$f.absent"; fi
  done
  [ -d "$SUP/workday" ] && cp -R "$SUP/workday" "$WORK/data/workday"
  ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep '^com.momominibot.freeflow.task\.' | sort > "$WORK/data/agents.list"
  ls "$SUP/scratchpad" 2>/dev/null | sort > "$WORK/data/scratch.list"
  ls "$SUP/meetings" 2>/dev/null | sort > "$WORK/data/meetings.list"
  defaults export $DOM "$WORK/data/prefs.plist" >/dev/null 2>&1
}

restore_data() {
  local f
  pkill -x FreeFlow >/dev/null 2>&1; sleep 1; pkill -9 -x FreeFlow >/dev/null 2>&1; sleep 0.5
  for f in dictionary.txt learned.txt snippets.txt styles.txt modes.json history.jsonl history.txt; do
    if [ -f "$WORK/data/$f" ]; then cp -p "$WORK/data/$f" "$SUP/$f"; elif [ -f "$WORK/data/$f.absent" ]; then rm -f "$SUP/$f"; fi
  done
  local x
  for x in $(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep '^com.momominibot.freeflow.task\.'); do
    grep -qxF -- "$x" "$WORK/data/agents.list" || { launchctl bootout "gui/$(id -u)/${x%.plist}" >/dev/null 2>&1; rm -f "$HOME/Library/LaunchAgents/$x"; }
  done
  rm -rf "$SUP/workday"; [ -d "$WORK/data/workday" ] && cp -R "$WORK/data/workday" "$SUP/workday"
  for x in $(ls "$SUP/scratchpad" 2>/dev/null); do grep -qxF -- "$x" "$WORK/data/scratch.list" || rm -rf "$SUP/scratchpad/$x"; done
  for x in $(ls "$SUP/meetings" 2>/dev/null); do grep -qxF -- "$x" "$WORK/data/meetings.list" || rm -rf "$SUP/meetings/$x"; done
  [ -f "$WORK/data/prefs.plist" ] && defaults import $DOM "$WORK/data/prefs.plist" >/dev/null 2>&1
  # import adds and changes keys but never removes one, so take out every key the run introduced
  for k in debugTriggers workdayInterval workdayOn meetingMode meetingCountdown learnFromTyping typingSeen fixesByDay screenTextOn typingDetailOn keepPictures detailInterval doubleTapToStart unsentPopup showInDock learnTypingAtOnce takesLimit takesDays takesFolder keepTakes; do
    plutil -extract "$k" raw -o - "$WORK/data/prefs.plist" >/dev/null 2>&1 || defaults delete $DOM "$k" >/dev/null 2>&1
  done
  open "$APP"
}

live_ui() {
  stage "The window: every page, button and setting"
  mkdir -p "$WORK/tools"
  swiftc -O scripts/tools/winsof.swift -o "$WORK/winsof" -framework CoreGraphics >/dev/null 2>&1
  if swiftc -O scripts/tools/axclick.swift -o "$WORK/axclick" -framework AppKit -framework ApplicationServices >"$WORK/axbuild.log" 2>&1; then AX="$WORK/axclick"; else bad "could not build the Accessibility helper"; tail -3 "$WORK/axbuild.log"; return; fi
  press()  { "$AX" FreeFlow press "$1" >/dev/null 2>&1; sleep "${2:-0.7}"; }
  has()    { "$AX" FreeFlow list 2>/dev/null | grep -qF -- "$1"; }
  see()    { if has "$2"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
  gone()   { if has "$2"; then bad "$1 (still there: $2)"; else ok "$1"; fi; }
  post "home:home"; sleep 2.5
  "$AX" FreeFlow list >/dev/null 2>&1; [ $? -eq 2 ] && { bad "Accessibility is not trusted for the helper"; return; }
  press Home; see "Home page" "total words"
  press Meetings;    see "Meetings page" "Take notes now"
  see "Meetings page shows the call settings summary" "Call settings"
  press "Call settings"; see "Call settings opens Settings > Calls" "Meeting detection"; press Close
  press Stats;       see "Stats page" "words this week"
  press Words;       see "Words page" "Teach it your words."
  press Phrases;     see "Phrases page" "Say a little, type a lot."
  press Tone;        see "Tone page" "How should it write?"
  press Rewrites;    see "Rewrites page" "Make it shorter"
  press Jots;        see "Jots page" "Save note"
  press Learning;    see "Learning page" "Is it getting better?"
  see "Learning page offers learning from your own typing" "Learn from my own typing"
  press Help;        see "Help page" "Quick start"
  press Home
  press Search;      see "Dictation search opens" "AXTextField"
  press Search;      gone "Dictation search closes" "AXTextField"
  if has "Open Jots"; then press "Open Jots"; see "Open Jots button" "Save note"; press Home; fi
  press "See your insights"; see "See your insights button" "words this week"
  press Home
  press "Hide the sidebar"; gone "Sidebar hides" "AXButton Jots"
  press "Show the sidebar"; see "Sidebar shows again" "AXButton Jots"

  press Settings;    see "Settings opens" "Talk key"
  see "Appearance card" "Match my Mac"
  for t in System Calls MCP Team; do press "$t" 0.6; done
  press General;     see "General tab" "Talk key"
  press System;      see "System tab" "Launch app at login"
  press Calls;       see "Calls tab" "Meeting detection"
  press MCP;         see "MCP tab" "Copy command"
  press Account;     see "Account tab" "First name"
  press Team;        see "Team tab" "Shared folder"
  press "Data and Privacy"; see "Data and Privacy tab" "Keep my recordings on this Mac"
  # with recordings switched on, how many, how long and where can be chosen (and the switch goes back off)
  defaults write $DOM keepTakes -bool true; press Calls; press "Data and Privacy"
  see "recordings: how many to keep can be chosen" "How many to keep"
  see "recordings: how long to keep them can be chosen" "How long to keep them"
  see "recordings: the folder can be chosen" "Choose folder"
  defaults write $DOM keepTakes -bool false
  press Close;       gone "Settings closes" "Talk key"
  press "Share with team"; see "Share with team opens Team" "Shared folder"; press Close
  press "Connect your AI tools"; see "Connect your AI tools opens the MCP tab" "Copy command"; press Close
  press Account;     see "Account button opens Account" "First name"; press Close

  # appearance, saved and applied
  local before; before=$(defaults read $DOM appearance 2>/dev/null || echo system)
  press Settings 1
  press "Light" 1;          [ "$(defaults read $DOM appearance)" = light ] && ok "Light chip saves light" || bad "Light chip"
  has "| Dark purple" && ok "top button offers the moon while light" || bad "top button while light"
  press "Match my Mac" 1;   [ "$(defaults read $DOM appearance)" = system ] && ok "Match my Mac chip saves system" || bad "Match my Mac chip"
  press Close
  press "Dark purple" 1.2;  [ "$(defaults read $DOM appearance)" = dark ] && ok "moon button saves dark" || bad "moon button"
  has "| Light colours" && ok "top button becomes the sun in dark" || bad "sun button in dark"
  press "Light colours" 1.2; [ "$(defaults read $DOM appearance)" = light ] && ok "sun button saves light" || bad "sun button"
  defaults write $DOM appearance "$before"

  # every list takes a new entry and writes it to its file (the files are put back at the end)
  press Words; press "Add new word" 0.8
  "$AX" FreeFlow set "Ranklore" "Smokeword" >/dev/null 2>&1; sleep 0.3; press "Add" 0.8
  grep -qi smokeword "$SUP/dictionary.txt" 2>/dev/null && ok "Dictionary adds a word to its file" || bad "Dictionary add"
  press Phrases; press "Add new snippet" 0.8
  "$AX" FreeFlow set "When I say" "my test address" >/dev/null 2>&1; "$AX" FreeFlow set "Type this" "12 Smoke Street" >/dev/null 2>&1; sleep 0.3; press "Add snippet" 0.8
  grep -qi "my test address" "$SUP/snippets.txt" 2>/dev/null && ok "Snippets adds a snippet to its file" || bad "Snippets add"
  press Tone
  "$AX" FreeFlow set "Name" "Smoke tone" >/dev/null 2>&1; "$AX" FreeFlow set "How should it write" "Be very brief." >/dev/null 2>&1; sleep 0.3; press "Add tone" 0.8
  grep -qi "smoke tone" "$SUP/modes.json" 2>/dev/null && ok "Tone adds a tone to its file" || bad "Tone add"
  press Rewrites
  "$AX" FreeFlow set "Name" "Smoke transform" >/dev/null 2>&1; "$AX" FreeFlow set "What should it do" "Make it rhyme." >/dev/null 2>&1; sleep 0.3; press "Add transform" 0.8
  grep -qi "smoke transform" "$SUP/modes.json" 2>/dev/null && ok "Transforms adds a transform to its file" || bad "Transforms add"
  press Jots
  "$AX" FreeFlow set "Write something" "smoke note body" >/dev/null 2>&1; sleep 0.3; press "Save note" 0.8
  grep -rqi "smoke note body" "$SUP/scratchpad" 2>/dev/null && ok "Jots saves a note to a file" || bad "Jots save"
  press Home
}

live_voice() {
  stage "Dictation, notes to self, paste, transforms and edit by voice"
  # volume must be audible, or `say` cannot reach the microphone
  local vol muted
  vol=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null); muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
  if [ "$muted" = true ] || [ "${vol:-0}" -lt 25 ] 2>/dev/null; then SAY_OK=0; bad "speakers are muted or too quiet (volume $vol): the voice tests cannot run"; return; fi

  # the tidy-up model is loaded before the voice tests, so a cold start is not mistaken for a broken dictation
  local w0 w1; w0=$(date +%s)
  if tmo 180 "$BIN" --test-ai "warming up the model for the voice tests please" neutral >/dev/null 2>&1; then w1=$(date +%s); ok "the local AI is warm ($((w1 - w0))s)"; else bad "the local AI did not answer within 180 s"; fi

  # plain dictation: hold the key, speak, let go
  te_new; local hist0 off; hist0=$(wc -l < "$SUP/history.jsonl" 2>/dev/null || echo 0); off=$(loglen)
  post down; sleep 1; play dictation; sleep 0.7; post up
  if wait_for 30 te_has thursday; then ok "dictation is typed into the app in front: \"$(te_text | tr '\n' ' ' | cut -c1-70)\""; else bad "dictation did not arrive in TextEdit"; logsince "$off" | tail -5; fi
  te_has "Maria" && ok "a name is spelled with its capital" || bad "the name Maria lost its capital"
  te_has "?" && ok "the question keeps its question mark" || bad "the question mark was lost"
  if wait_for 10 sh -c "[ \$(wc -l < '$SUP/history.jsonl') -gt $hist0 ]"; then ok "the dictation is written to history"; else bad "history did not grow"; fi
  logsaw "$off" "transcribed" && ok "the log shows the take was transcribed" || bad "no transcription line in the log"

  # tap once to start, speak, tap again to finish (hands-free)
  te_new; off=$(loglen)
  post tap; sleep 1.5; play tapmode; sleep 0.8; post tap
  if wait_for 30 te_has venue; then ok "tap to start, tap again to finish types what was said: \"$(te_text | tr '\n' ' ' | cut -c1-60)\""; else bad "tap-to-start dictation did not arrive"; logsince "$off" | tail -4; fi

  # double tap (as in Wispr Flow): one quick tap starts nothing, two quick taps start hands-free, two quick taps finish
  post gesture:double; te_new; off=$(loglen)
  post tap; sleep 1.2
  logsaw "$off" "one quick tap, waiting for a second" && ok "double-tap mode: one quick tap on its own starts nothing" || bad "double-tap mode: the single tap was not ignored"
  logsaw "$off" "double tap, hands-free is on" && bad "double-tap mode: one tap started hands-free" || ok "double-tap mode: one tap did not start hands-free"
  off=$(loglen)
  post tap:double; sleep 1.5
  logsaw "$off" "double tap, hands-free is on" && ok "double-tap mode: two quick taps start hands-free" || bad "double-tap mode: two taps did not start hands-free"
  post tap; sleep 1.2        # one stray tap while listening must not end it
  logsaw "$off" "one quick tap while listening" && ok "double-tap mode: one tap while listening is ignored" || bad "double-tap mode: the single tap while listening was not noticed"
  logsaw "$off" "double tap, finishing" && bad "double-tap mode: one tap finished the dictation" || ok "double-tap mode: one tap did not finish it"
  play tapmode; sleep 0.8; post tap:double
  wait_for 10 logsaw "$off" "double tap, finishing" && ok "double-tap mode: two quick taps finish it" || bad "double-tap mode: two taps did not finish it"
  if wait_for 30 te_has venue; then ok "double tap to start and to finish types what was said: \"$(te_text | tr '\n' ' ' | cut -c1-60)\""; else bad "double-tap dictation did not arrive"; logsince "$off" | tail -4; fi
  post gesture:one

  # a snippet expands the words said into the text saved for them
  te_new; off=$(loglen)
  post down; sleep 1; play snippet; sleep 0.7; post up
  if wait_for 30 te_has "12 Smoke Street"; then ok "a snippet expands to its text"; else bad "snippet did not expand (typed: $(te_text | tr '\n' ' ' | cut -c1-60))"; fi

  # a note to self goes to the Scratchpad, not the app
  te_new; local n0 off2; n0=$(count_files "$SUP/scratchpad"); off2=$(loglen)
  post down; sleep 1; play note; sleep 0.7; post up
  if wait_for 30 sh -c "[ \$(ls '$SUP/scratchpad' | wc -l | tr -d ' ') -gt $n0 ]"; then ok "\"note to self\" is saved to the Scratchpad"; else bad "no scratchpad note was made"; logsince "$off2" | tail -4; fi
  grep -rqi "dentist" "$SUP/scratchpad" 2>/dev/null && ok "the note holds what was said" || bad "the note is missing the words"
  te_has dentist && bad "the note to self was also typed into the app" || ok "nothing was typed into the app in front"

  # the paste path (used when typing is not allowed)
  te_new; post paste
  wait_for 15 te_has "Paste test from FreeFlow" && ok "pasting a result into the app in front works" || bad "paste test"

  # a saved transform on the selected text
  local long="I just wanted to quickly write to you today to let you know that, as far as I can tell, the meeting that we had planned for Thursday afternoon at three o'clock is probably going to have to be moved to some other day next week, because a few of the people who really need to be there are not able to come."
  te_new; te_set "$long"; local off3 words0; off3=$(loglen); words0=$(echo "$long" | wc -w | tr -d ' ')
  post "transform:shorter"
  if wait_for 60 sh -c "tail -n +$(( off3 + 1 )) '$LOG' | grep -q 'transform Make it shorter'"; then
    sleep 1; local words1; words1=$(te_text | wc -w | tr -d ' ')
    [ "$words1" -lt "$words0" ] && [ "$words1" -gt 3 ] && ok "\"Make it shorter\" replaced the selection ($words0 words to $words1)" || bad "transform text did not get shorter ($words0 to $words1)"
  else bad "transform did not run"; logsince "$off3" | tail -4; fi

  # edit by voice: hold the command key, say what to change
  te_new; te_set "$long"; local off4; off4=$(loglen)
  post command; sleep 1; play command; sleep 0.7; post up
  if wait_for 60 sh -c "[ \$(osascript -e 'tell application \"TextEdit\" to get text of front document' | wc -w | tr -d ' ') -lt $words0 ]"; then ok "edit by voice shortened the selected text"; else bad "edit by voice did not change the text"; logsince "$off4" | tail -5; fi

  # every state of the bar draws without a crash
  local s; for s in idle listening handsfree working "message:Learned: Ranklor to Ranklore" "message:smoke"; do post "pill:$s"; sleep 0.4; done
  pgrep -x FreeFlow >/dev/null && ok "the bar shows every state without crashing" || bad "the app died while showing the bar"

  # learning: fix a word in the text FreeFlow typed and it notices the pair (a dry run, nothing is saved)
  te_new
  osascript -e 'tell application "TextEdit" to set text of front document to "FFPROBE we love ranklor so much"' >/dev/null 2>&1
  "$BIN" --probe-learn "FFPROBE we love ranklor so much" --probe-activate com.apple.TextEdit >"$WORK/learn.log" 2>&1 &
  local lp=$!
  sleep 4
  osascript -e 'tell application "TextEdit" to set text of front document to "FFPROBE we love Ranklore so much"' >/dev/null 2>&1
  wait_for 50 sh -c "! kill -0 $lp 2>/dev/null"
  kill $lp 2>/dev/null
  grep -q "^watching" "$WORK/learn.log" && ok "the correction watcher finds the typed text in the app" || bad "the correction watcher could not find the text"
  grep -qi "ranklor -> Ranklore" "$WORK/learn.log" && ok "a corrected word is learned (ranklor -> Ranklore)" || { bad "no pair was learned"; cat "$WORK/learn.log" | tail -3; }
  te_close_ours
}

live_typing() {
  stage "Learning from my own typing (opt-in): a name backspaced and written again"
  local lf="$SUP/learned.txt" off
  if ! te_front; then post typing:off; skp "TextEdit could not be brought to the front, so no keystrokes were sent (they would have gone to another app)"; return; fi
  post typing:once:off; post typing:on; sleep 1.5; off=$(loglen)
  te_new
  # with "keep a clear fix the first time" off, the same name must be fixed twice: typed, left to settle, backspaced, written again (a name no other stage uses, so they cannot affect each other)
  tp "FFTYPE we love Quillmor so much."; sleep 2.5; bk 17; sleep 0.3; tp "Quillmore so much."; sleep 2.5
  grep -q "Quillmore" "$lf" 2>/dev/null && bad "one fix was already learned" || ok "one fix teaches nothing yet"
  nl; tp "FFTYPE again Quillmor today."; sleep 2.5; bk 15; sleep 0.3; tp "Quillmore today."; sleep 3
  if wait_for 12 logsaw "$off" "typing: learned Quillmor -> Quillmore"; then ok "the same fix twice is learned (Quillmor to Quillmore)"; else bad "the fix was not learned"; logsince "$off" | grep typing | tail -3; fi
  grep -q "Quillmore" "$lf" 2>/dev/null && ok "the spelling is in learned.txt, so the speech engine gets it as a hint" || bad "learned.txt does not hold the spelling"
  # a typo fixed into an everyday word is not worth keeping
  nl; tp "FFTYPE teh cat sat today."; sleep 2.5; bk 18; sleep 0.3; tp "the cat sat today."; sleep 2.5
  nl; tp "FFTYPE teh dog ran today."; sleep 2.5; bk 18; sleep 0.3; tp "the dog ran today."; sleep 3
  grep -qi "| teh |" "$lf" 2>/dev/null && bad "an ordinary typo was learned" || ok "a typo fixed into an everyday word is ignored"
  # privacy: no text is kept, only the word
  { grep -rq "FFTYPE" "$lf" 2>/dev/null || defaults read $DOM 2>/dev/null | grep -q "FFTYPE"; } && bad "typed text was stored" || ok "no typed text is stored anywhere, only the spelling"
  # with "keep a clear fix the first time" on, one clear spelling fix is kept, but only after it has stood for 20 seconds
  post typing:once:on; sleep 0.5; off=$(loglen)
  nl; tp "FFTYPE we love Brandlewik so much."; sleep 2.5; bk 19; sleep 0.3; tp "Brandlewick so much."; sleep 4
  grep -q "Brandlewick" "$lf" 2>/dev/null && bad "a clear fix was kept at once, without waiting" || ok "a clear fix waits a little before it is kept"
  if wait_for 45 logsaw "$off" "typing: learned Brandlewik -> Brandlewick"; then ok "one clear spelling fix is kept the first time (Brandlewik to Brandlewick)"; else bad "the clear fix was not kept"; logsince "$off" | grep typing | tail -3; fi
  grep -q "Brandlewick" "$lf" 2>/dev/null && ok "the first-time fix is in learned.txt" || bad "learned.txt does not hold the first-time fix"
  # a half-deleted word is not a fix, even with that on
  off=$(loglen)
  nl; tp "FFTYPE open the Zephyrcom"; sleep 2.5; bk 9; sleep 0.3; tp "Zeph"; sleep 4
  logsaw "$off" "typing: learned" && bad "a half-deleted word was learned" || ok "a half-deleted word is not learned"
  # switched off, it learns nothing
  post typing:off; sleep 1
  nl; tp "FFTYPE we use Zorbitron today."; sleep 2.5; bk 16; sleep 0.3; tp "Zorbitrone today."; sleep 2.5
  nl; tp "FFTYPE we use Zorbitron again."; sleep 2.5; bk 15; sleep 0.3; tp "Zorbitrone again."; sleep 3
  grep -q "Zorbitrone" "$lf" 2>/dev/null && bad "it learned while switched off" || ok "switched off, it learns nothing"
  te_close_ours
}

live_detail() {
  stage "Deeper notes (opt-in): the text on the screen, how I type, small pictures, forgetting"
  local dd="$SUP/workday/detail" today; today=$(date +%F)
  if ! te_front; then skp "TextEdit could not be brought to the front, so the deeper notes were not tried"; return; fi
  post detail:forget; sleep 1
  [ ! -d "$dd" ] && ok "nothing is kept until the switches are on" || bad "detail files exist before anything was switched on"
  local off; off=$(loglen)
  post detail:typing:on; post detail:screen:on; sleep 1.5
  te_new
  # typed in pieces the way a person types (more than 40 characters in one second counts as a paste, not typing), then left alone
  tp "Zebra harvest invoice "; sleep 1.3; tp "schedule for the Monday "; sleep 1.3; tp "shipment. Send it to "; sleep 1.3; tp "jamie@example.com please."; sleep 5
  bk 13; sleep 0.4; tp " right away."; sleep 3
  post detail:flush; sleep 1.5
  python3 - "$dd/typing-$today.jsonl" <<'PYEOF' && ok "a typing minute is noted (typed and deleted counts, the finished line, the email already a tag)" || bad "no usable typing record"
import json, os, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()] if os.path.exists(sys.argv[1]) else []
r = [x for x in recs if x.get("typed", 0) > 20 and x.get("deleted", 0) > 5]
assert r, recs
t = " ".join(x.get("text", "") for x in r)
assert "jamie@example.com" not in t, t
assert "<email>" in t, t
PYEOF
  grep -rq "jamie@example.com" "$dd" 2>/dev/null && bad "a raw email address reached the notes" || ok "no raw email address anywhere in the deeper notes"
  # the words on the screen
  te_front; sleep 1.2; post detail:snap
  if wait_for 40 sh -c "tail -n +$((off+1)) '$LOG' | grep -qE 'screen: (read [0-9]+ characters|could not|nothing readable|unchanged|not reading|still busy|Screen Recording is not allowed)'"; then
    if logsince "$off" | grep -q "Screen Recording is not allowed"; then
      skp "Screen Recording is not allowed for FreeFlow on this Mac, so the screen text could not be tried"
    elif logsince "$off" | grep -qE "screen: read [0-9]+ characters"; then
      ok "the window's text is read ($(logsince "$off" | grep -E 'screen: read [0-9]+ characters' | tail -1 | sed 's/.*screen: //'))"
      local hits try=0
      while :; do
        cp "$dd/screen-$today.jsonl" "$WORK/screen-record.jsonl" 2>/dev/null
        hits=$(tr 'A-Z' 'a-z' < "$dd/screen-$today.jsonl" 2>/dev/null | grep -o -E "zebra|harvest|invoice|schedule|monday|shipment" | sort -u | wc -l | tr -d ' ')
        [ "${hits:-0}" -ge 3 ] || [ $try -ge 1 ] && break
        # one retry: the window may have been caught while it was still drawing
        try=$((try+1)); tp " Again."; sleep 1.5; te_front; post detail:snap; sleep 12
      done
      [ "${hits:-0}" -ge 3 ] && ok "the screen record holds the words on the window ($hits of 6 test words found)" || bad "the screen record is missing the window's words ($hits of 6)"
      [ ! -d "$dd/pictures" ] && ok "no picture is kept unless that switch is on" || bad "a picture was kept without the switch"
      post detail:pictures:on; tp " Second line about the Tuesday refund and the warehouse."; sleep 2; te_front; post detail:snap
      wait_for 25 sh -c "ls '$dd/pictures/$today'/*.jpg" && ok "with the pictures switch on, a small picture is kept" || bad "no picture was kept with the switch on"
      local kb; kb=$(du -k "$dd/pictures/$today"/*.jpg 2>/dev/null | head -1 | cut -f1)
      [ -n "$kb" ] && [ "$kb" -lt 600 ] && ok "the picture is small (${kb} KB)" || bad "the picture is not small (${kb:-none} KB)"
      post detail:pictures:off
    else
      bad "the screen was not read"; logsince "$off" | grep screen: | tail -3
    fi
  else
    bad "the screen read gave no answer"
  fi
  # an agent can read it through the MCP server
  python3 - <<'PYEOF' && ok "the MCP server hands the notes to an agent (workday_detail)" || bad "workday_detail returned nothing usable"
import json, subprocess
def rpc(*msgs):
    p = subprocess.run(["python3", "scripts/freeflow-mcp.py"], input="\n".join(json.dumps(m) for m in msgs) + "\n", capture_output=True, text=True, timeout=30)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
out = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}},
          {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "workday_detail", "arguments": {"kind": "typing"}}})
res = [o for o in out if o.get("id") == 2][0]["result"]
body = json.loads(res["content"][0]["text"])
assert body["typing_notes_are_on"] is True and body["records"], body
assert all("jamie@example.com" not in json.dumps(r) for r in body["records"])
PYEOF
  # switched off, nothing more is written; forgetting removes everything
  post detail:typing:off; post detail:screen:off; sleep 1
  local before; before=$(cat "$dd"/*.jsonl 2>/dev/null | wc -c | tr -d ' ')
  tp " More words typed while the notes are off, ok."; sleep 3; post detail:flush; sleep 1.5; te_front; post detail:snap; sleep 3
  [ "$(cat "$dd"/*.jsonl 2>/dev/null | wc -c | tr -d ' ')" = "$before" ] && ok "switched off, nothing more is written (typing or screen)" || bad "notes were written while switched off"
  post detail:forget; sleep 1
  [ ! -d "$dd" ] && ok "Forget removes the notes and the pictures" || bad "detail files remain after Forget"
  te_close_ours
}

live_unsent() {
  stage "A dictation that did not reach a text box: the card with the words"
  # the same Accessibility helper the window stage uses (built here too, so this stage can run on its own)
  if [ -z "${AX:-}" ] || [ ! -x "${AX:-}" ]; then
    swiftc -O scripts/tools/axclick.swift -o "$WORK/axclick" -framework AppKit -framework ApplicationServices >"$WORK/axbuild.log" 2>&1 && AX="$WORK/axclick" || { bad "could not build the Accessibility helper"; return; }
  fi
  type press >/dev/null 2>&1 || press() { "$AX" FreeFlow press "$1" >/dev/null 2>&1; sleep "${2:-0.7}"; }
  type has >/dev/null 2>&1 || has() { "$AX" FreeFlow list 2>/dev/null | grep -qF -- "$1"; }
  [ "$SAY_OK" = 1 ] || { skp "speakers not usable, so the spoken part of the card test was skipped"; }
  local off

  # 1. the card, and Copy
  off=$(loglen); post unsent:show; sleep 1.5
  if has "This did not reach a text box"; then ok "the card appears with its title"; else bad "the card did not appear"; fi
  has "Test: this dictation did not reach a text box." && ok "the card shows the words" || bad "the card does not show the words"
  has "Paste again" && has "Close" && ok "the card offers Copy, Paste again and Close" || bad "the card is missing a button"
  printf 'not the words' | pbcopy
  press Copy 0.5
  [ "$(pbpaste)" = "Test: this dictation did not reach a text box." ] && ok "Copy puts the words on the clipboard" || bad "Copy did not copy the words ($(pbpaste | cut -c1-40))"
  sleep 1.8
  has "This did not reach a text box" && bad "the card did not close after Copy" || ok "the card closes after Copy"

  # 2. Paste again types the words into the box you were in, and the card never took your keyboard focus
  te_new; post unsent:show; sleep 1.5
  press "Paste again" 0.8
  if wait_for 10 te_has "Test: this dictation did not reach a text box"; then ok "Paste again types the words into the box you were in (the card never took the focus)"; else bad "Paste again did not type into TextEdit ($(te_text | cut -c1-50))"; fi
  has "This did not reach a text box" && bad "the card stayed after Paste again" || ok "the card goes away after Paste again"
  te_close_ours

  # 3. the real thing: you switch to another app before the words are ready
  if [ "$SAY_OK" = 1 ]; then
    te_new; off=$(loglen)
    post down; sleep 1
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    play dictation; sleep 0.7; post up
    if wait_for 40 logsaw "$off" "unsent: shown (You switched to"; then ok "dictating, then switching apps, shows the card instead of losing the words"; else bad "no card after switching apps"; logsince "$off" | tail -4; fi
    wait_for 10 has "Paste again" || true; sleep 0.6      # the card is on screen and readable before it is pressed
    # the words were copied when the card appeared, so the button already reads "Copied"; pressing it copies them again
    has "Copied" && ok "the card says the words are already copied" || bad "the card does not say the words are copied"
    printf 'not the words' | pbcopy
    if has "Copied"; then press Copied 0.5; else press Copy 0.5; fi
    pbpaste | grep -qi thursday && ok "the card holds what was said, and Copy copies it ($(pbpaste | tr '\n' ' ' | cut -c1-50))" || bad "the card's words are missing what was said ($(pbpaste | cut -c1-50))"
    sleep 1.8
    post unsent:hide
    te_close_ours
  fi
}

live_notes() {
  stage "Meeting notes, summaries and audio files"
  [ "$SAY_OK" = 1 ] || { bad "skipped: speakers not usable"; return; }
  # a meeting: start, talk, stop
  local m0 off; m0=$(count_files "$SUP/meetings"); off=$(loglen)
  post meeting:start; sleep 3
  play meeting
  sleep 1; post meeting:stop
  if wait_for 90 logsaw "$off" "notes saved"; then ok "meeting notes are saved after Stop ($(logsince "$off" | grep 'notes saved' | tail -1 | sed 's/.*notes saved, //'))"; else bad "meeting notes were not saved"; logsince "$off" | tail -6; fi
  local f; f=$(ls -t "$SUP/meetings" | grep -v '^\.' | head -1)
  [ "$(count_files "$SUP/meetings")" -gt "$m0" ] && ok "a note file exists: $f" || bad "no new note file"
  grep -qiE "launch|thursday|invoice" "$SUP/meetings/$f" 2>/dev/null && ok "the note holds the spoken words" || bad "the note is missing the spoken words"
  # the other side of a call: with Screen & System Audio allowed, the note is written from both the microphone and what the Mac plays
  if logsince "$off" | grep -q "both sides true"; then
    grep -q "You and the others" "$SUP/meetings/$f" 2>/dev/null && ok "the other side of the call is heard too (the note says: You and the others)" || bad "both sides were on, but the note does not say so"
  else skp "Screen & System Audio Recording is not allowed for FreeFlow, so only your side of a call is written"; fi
  if wait_for 120 logsaw "$off" "summary: done"; then ok "the AI summary is added by itself"; else bad "no summary was written"; logsince "$off" | grep summary | tail -3; fi
  grep -qiE "summary|action|decision" "$SUP/meetings/$f" 2>/dev/null && ok "the note file has a summary section" || bad "no summary section in the note"

  # an audio file
  local m1 off2; m1=$(count_files "$SUP/meetings"); off2=$(loglen)
  post "file:$WORK/voice/file.wav"
  if wait_for 120 sh -c "[ \$(ls '$SUP/meetings' | wc -l | tr -d ' ') -gt $m1 ]"; then ok "an audio file is written down to a note"; else bad "audio file did not become a note"; logsince "$off2" | tail -4; fi
  f=$(ls -t "$SUP/meetings" | head -1)
  grep -qiE "price|monday|weekend" "$SUP/meetings/$f" 2>/dev/null && ok "the file note holds the spoken words" || bad "the file note is missing the words"
}

live_workday() {
  stage "Workday: recording, privacy, ideas and a scheduled task"
  press Workday 1.5; see "Workday page" "Keep workday notes"
  see "Workday page explains it keeps no screenshots" "Keep workday notes"
  see "Workday page offers the deeper notes, switched off by themselves" "Read the text on my screen"
  see "Workday page offers noting how I type" "Note how I type"
  see "Workday page offers small pictures as a separate switch" "Keep small pictures of the window too"
  see "Workday page can forget the deeper notes" "Forget the deeper notes"
  if [ -x "$HOME/.local/bin/hermes" ] || [ -x "$HOME/.local/bin/fleet-bridge" ]; then
    see "Workday page can ask Hermes for a closer look" "Ask Hermes for a closer look"
    see "Workday page can test the Hermes connection" "Test the connection"
  fi
  if [ -x "$HOME/.local/bin/hermes" ]; then
    # makes a card nobody is assigned to, then closes it: nothing runs, nothing is spent
    local hoff; hoff=$(loglen); post hermes:check
    if wait_for 90 logsaw "$hoff" "hermes: connection works"; then ok "the Hermes connection works (a test card was made and closed)"
    else bad "the Hermes connection did not work"; logsince "$hoff" | grep -i hermes | tail -2; fi
  fi

  # recording, with a window whose title holds an email address, to prove it is cleaned before it is stored
  local f="/private/tmp/ff-smoke-jamie@example.com.txt" today; today=$(date +%F)
  cliclick m:+1,+0 >/dev/null 2>&1; cliclick m:-1,+0 >/dev/null 2>&1           # a real input event: after 3 minutes without one the notes (rightly) count it as idle
  post workday:on; sleep 1.5
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 4
  printf 'smoke\n' > "$f"
  cliclick m:+1,+0 >/dev/null 2>&1; cliclick m:-1,+0 >/dev/null 2>&1
  osascript -e "tell application \"TextEdit\" to open POSIX file \"$f\"" >/dev/null 2>&1; sleep 1; osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1; sleep 4
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 3
  post workday:flush; sleep 1
  local file="$SUP/workday/$today.jsonl"
  [ -s "$file" ] && ok "the notes are written to a day file" || bad "no workday file was written"
  grep -q '"name":"Finder"' "$file" 2>/dev/null && grep -q '"name":"TextEdit"' "$file" 2>/dev/null && ok "the apps you used are in the notes" || bad "Finder and TextEdit are not both in the notes"
  grep -q "example.com" "$file" 2>/dev/null && bad "an email address from a window title was stored" || ok "the email address in a window title was never stored"
  grep -q "<email>" "$file" 2>/dev/null && ok "it was swapped for a tag" || bad "the window title was not recorded with the tag"
  post workday:off; sleep 1; local n0 n1; n0=$(wc -l < "$file" 2>/dev/null | tr -d ' '); sleep 4; n1=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  [ "$n0" = "$n1" ] && ok "switching the notes off really stops recording" || bad "it kept recording after being switched off"
  osascript -e "tell application \"TextEdit\" to close (first document whose name is \"ff-smoke-jamie@example.com.txt\") saving no" >/dev/null 2>&1; rm -f "$f"

  # ideas from five earlier days (made up for this check) and from three repeated dictations
  /opt/homebrew/bin/python3.14 - "$SUP" <<'PYEOF2'
import json, os, sys, time, datetime
sup = sys.argv[1]; d = os.path.join(sup, "workday"); os.makedirs(d, exist_ok=True)
def ep(day, h, m): return int(time.mktime((day.year, day.month, day.day, h, m, 0, 0, 0, -1)))
for back in range(1, 6):
    day = datetime.date.today() - datetime.timedelta(days=back)
    rows = [("com.google.Chrome", "Google Chrome", 8, 50, 10), ("com.tinyspeck.slackmacgap", "Slack", 9, 2, 5), ("com.apple.mail", "Mail", 9, 10, 5)]
    with open(os.path.join(d, day.isoformat() + ".jsonl"), "w") as f:
        for b, n, h, m, mins in rows:
            f.write(json.dumps({"s": ep(day, h, m), "e": ep(day, h, m) + mins * 60, "app": b, "name": n}) + "\n")
said = "Please install every skill that is required for this job and use the AI visibility playbook until the whole project is complete"
with open(os.path.join(sup, "history.jsonl"), "a") as f:
    for i in range(3):
        f.write(json.dumps({"app": "com.apple.TextEdit", "t": (datetime.datetime.utcnow() - datetime.timedelta(hours=i + 1)).strftime("%Y-%m-%dT%H:%M:%SZ"), "mode": "medium", "raw": said, "text": f"Hello number {i}. {said}."}) + "\n")
PYEOF2
  press Home 1; press Workday 3.5
  see "an idea to open the morning apps is offered" "Add to my schedule"
  see "an idea to save a repeated sentence is offered" "Make a phrase"
  press "Run a check" 1; see "Run a check shows what it would open" "opens Google Chrome"
  local before after; before=$(ls "$HOME/Library/LaunchAgents" | grep -c '^com.momominibot.freeflow.task\.')
  press "Add to my schedule" 2
  after=$(ls "$HOME/Library/LaunchAgents" | grep -c '^com.momominibot.freeflow.task\.')
  [ "$after" -gt "$before" ] && ok "Add to my schedule writes the schedule file" || bad "no schedule file was written"
  local plist label; plist=$(ls -t "$HOME/Library/LaunchAgents"/com.momominibot.freeflow.task.*.plist 2>/dev/null | head -1); label=$(basename "$plist" .plist)
  plutil -lint "$plist" >/dev/null 2>&1 && ok "macOS accepts the schedule file" || bad "the schedule file is invalid"
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && ok "macOS has loaded the task and will run it" || bad "macOS did not load the task"
  local script; script=$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$plist" 2>/dev/null)
  [ -n "$script" ] && bash -n "$script" 2>/dev/null && [ "$(bash "$script" --dry-run | grep -c 'would open')" -ge 2 ] && ok "its script is valid and a dry run lists the apps" || bad "the task's script did not pass"
  press "Remove from my schedule" 2
  [ ! -e "$plist" ] && ok "Remove deletes the schedule file" || bad "the schedule file is still there"
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && bad "macOS still has the task loaded" || ok "macOS no longer has the task"
  [ ! -e "$script" ] && ok "Remove deletes the script too" || bad "the script was left behind"
  press "Make a phrase" 1.5
  grep -q "text =>" "$SUP/snippets.txt" 2>/dev/null && grep -qi "playbook" "$SUP/snippets.txt" && ok "Make a phrase saves the repeated sentence as a phrase" || bad "no phrase was saved"
  press "Forget everything" 1
  [ -z "$(ls "$SUP/workday"/*.jsonl 2>/dev/null)" ] && ok "Forget everything deletes the notes" || bad "notes were left after Forget everything"
  press Home
}

live_calls() {
  stage "Calls: noticed, notes start by themselves, stop when the call ends (the call is simulated, the rest is real)"
  [ "$SAY_OK" = 1 ] || { skp "speakers not usable, so the call tests were skipped"; return; }
  defaults write $DOM meetingMode auto; defaults write $DOM meetingCountdown -int 3
  local off m0; off=$(loglen); m0=$(count_files "$SUP/meetings")
  post call:zoom
  if wait_for 25 logsaw "$off" "call detected (Zoom), mode auto"; then ok "a Zoom call is noticed (two checks, about 6 s)"; else bad "the call was not noticed"; logsince "$off" | tail -3; fi
  # the offer card is on screen during the countdown
  local id="" i=0
  while [ $i -lt 20 ] && [ -z "$id" ]; do id=$("$WORK/winsof" FreeFlow 2>/dev/null | awk '$4>330 && $4<460 && $5<400 {print $1; exit}'); [ -n "$id" ] || sleep 0.3; i=$((i+1)); done
  if [ -n "$id" ] && screencapture -x -o -l "$id" "$WORK/call-card.png" 2>/dev/null && [ "$(stat -f %z "$WORK/call-card.png" 2>/dev/null || echo 0)" -gt 4000 ]; then ok "the offer card is on screen (picture: $WORK/call-card.png)"; else bad "no offer card was found on screen"; fi
  if wait_for 25 logsaw "$off" "notes started for Zoom"; then ok "notes start by themselves after the countdown"; else bad "the notes did not start"; logsince "$off" | tail -3; fi
  play meeting
  post call:none
  if wait_for 100 logsaw "$off" "notes saved"; then ok "the notes stop by themselves once the call has been over for a minute"; else bad "the notes did not stop after the call ended"; logsince "$off" | tail -4; fi
  local f; f=$(ls -t "$SUP/meetings" | head -1)
  [ "$(count_files "$SUP/meetings")" -gt "$m0" ] && grep -q "Zoom" "$SUP/meetings/$f" 2>/dev/null && ok "the note is named for the call (Zoom) and holds the words" || bad "the note is missing or not named for the call"

  # Ask mode: the card waits for you, nothing starts. Off mode: nothing is even offered.
  defaults write $DOM meetingMode ask; off=$(loglen)
  post call:zoom; wait_for 25 logsaw "$off" "call detected (Zoom), mode ask" && ok "in Ask mode the call is offered" || bad "Ask mode did not offer the call"
  sleep 8; logsaw "$off" "notes started" && bad "Ask mode started notes without being asked" || ok "in Ask mode nothing starts until you say so"
  post call:none; sleep 11
  defaults write $DOM meetingMode off; off=$(loglen)
  post call:zoom; sleep 11
  logsaw "$off" "call detected" && bad "Off mode still noticed a call" || ok "in Off mode a call is not even offered"
  post call:none; post call:real; defaults write $DOM meetingMode auto
}

live_mic() {
  stage "The real microphone watcher"
  local off; (perl -e 'alarm 14; exec @ARGV' ffmpeg -hide_banner -loglevel error -f avfoundation -i ":default" -t 9 -f null - >/dev/null 2>&1 &)
  sleep 3
  # every ffmpeg that is recording from the microphone (a wrapper or an older leftover must not be mistaken for it)
  local fpids fpid="" p; fpids=$(pgrep -f "ffmpeg.*avfoundation")
  "$BIN" --probe-meetings >"$WORK/probe-during.log" 2>&1
  for p in $fpids; do grep -q "^pid $p " "$WORK/probe-during.log" && fpid=$p; done
  if [ -n "$fpid" ]; then ok "a program recording from the microphone is seen (pid $fpid, not a call)"; else bad "the watcher did not see a program recording from the microphone"; head -4 "$WORK/probe-during.log"; fi
  sleep 8
  "$BIN" --probe-meetings >"$WORK/probe-after.log" 2>&1
  [ -n "$fpid" ] && ! grep -q "^pid $fpid " "$WORK/probe-after.log" && ok "and it is gone from the list when it stops" || bad "the program was still listed after it stopped"
}

# front_pid PID | front_name NAME: bring that app to the front and verify it, so no keystroke goes to anything else
front_pid() { local pid=$1 i=0; while [ $i -lt 30 ]; do osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1; [ "$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)" = "$pid" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
front_name() { local n=$1 i=0; while [ $i -lt 30 ]; do osascript -e "tell application \"$n\" to activate" >/dev/null 2>&1; [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "$n" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

learn_in() {   # learn_in LABEL chrome|safari  : the app notices a corrected word in a browser text box
  local label="$1" kind="$2" pid="" attempt=0 done_=0
  mkdir -p "$WORK/learn"
  printf '<!doctype html><title>ff-learn-test</title><body style="margin:0"><textarea autofocus rows="15" style="width:95%%;font-size:18px">FFPROBE we love ranklor so much</textarea></body>\n' > "$WORK/learn/learn.html"
  while [ $attempt -lt 2 ] && [ $done_ = 0 ]; do
    attempt=$((attempt+1))
    local front_ok=1
    if [ "$kind" = chrome ]; then
      open -na "Google Chrome" --args --user-data-dir="$WORK/learn/profile" --force-renderer-accessibility --no-first-run --no-default-browser-check "file://$WORK/learn/learn.html"
      wait_for 25 pgrep -f "user-data-dir=$WORK/learn/profile"; pid=$(pgrep -f "user-data-dir=$WORK/learn/profile" | head -1)
      [ -n "$pid" ] || { bad "$label: the test browser did not start"; return; }
      sleep 6; front_pid "$pid" || front_ok=0
    else
      open -a Safari "file://$WORK/learn/learn.html"; sleep 5
      front_name Safari || front_ok=0
    fi
    sleep 2
    if [ $front_ok = 0 ]; then
      # the focus could not be held: nothing was typed anywhere; close the test page and try once more
      echo "(attempt $attempt: $label could not be brought to the front)" >> "$WORK/learn/$kind.log"
    else
      "$BIN" --probe-learn "FFPROBE we love ranklor so much" >"$WORK/learn/$kind.log" 2>&1 &
      local lp=$! w=0
      while [ $w -lt 14 ] && ! grep -qE "watching|NOT WATCHING" "$WORK/learn/$kind.log" 2>/dev/null; do sleep 1; w=$((w+1)); done
      if grep -q "^watching" "$WORK/learn/$kind.log"; then
        if { [ "$kind" = chrome ] && front_pid "$pid"; } || { [ "$kind" = safari ] && front_name Safari; }; then
          ok "$label: the watcher finds the typed text in the browser's text box"
          osascript -e 'tell application "System Events" to keystroke "a" using command down' -e 'delay 0.3' -e 'tell application "System Events" to keystroke "FFPROBE we love Ranklore so much"' >/dev/null 2>&1
          wait_for 50 sh -c "! kill -0 $lp 2>/dev/null"
          grep -qi "ranklor -> Ranklore" "$WORK/learn/$kind.log" && ok "$label: the corrected word is learned (ranklor -> Ranklore)" || { bad "$label: nothing was learned"; tail -2 "$WORK/learn/$kind.log"; }
          done_=1
        fi
      fi
      kill $lp 2>/dev/null
    fi
    if [ $done_ = 0 ] && [ $attempt -ge 2 ]; then
      bad "$label: the watcher could not read the browser's text box after two tries ($(tail -1 "$WORK/learn/$kind.log" | cut -c1-80))"
    fi
    if [ "$kind" = chrome ]; then pkill -f "user-data-dir=$WORK/learn/profile" >/dev/null 2>&1
    else osascript -e 'tell application "Safari"' -e 'repeat with w in windows' -e 'repeat with t in (tabs of w)' -e 'if name of t is "ff-learn-test" then close t' -e 'end repeat' -e 'end repeat' -e 'end tell' >/dev/null 2>&1; fi
    sleep 1
  done
}

live_browsers() {
  stage "Learning from a correction inside browsers"
  learn_in "Chrome" chrome
  if [ -d /Applications/Safari.app ] || [ -d /System/Cryptexes/App/System/Applications/Safari.app ]; then learn_in "Safari" safari; else skp "Safari is not installed"; fi
}

live_follow_mac() {
  stage "Match my Mac"
  defaults write $DOM appearance system
  relaunch_app
  post home:home; sleep 2.5
  if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)" = Dark ]; then
    has "| Light colours" && ok "on this dark Mac, Match my Mac is dark purple" || bad "not dark on a dark Mac"
  else
    has "| Dark purple" && ok "on this light Mac, Match my Mac is light (the moon button is offered)" || bad "not light on a light Mac"
    skp "following a DARK Mac cannot be tested here: macOS 26 ignores a per-app dark override and a test must not change your Mac's own appearance. Flip System Settings > Appearance once to see it."
  fi
}

stage_release() {
  stage "The package teammates get"
  if ./build.sh release >"$WORK/release.log" 2>&1; then ok "build.sh release makes the package"; else bad "build.sh release"; tail -4 "$WORK/release.log"; return; fi
  local zip; zip=$(ls -t dist/FreeFlow-*.zip 2>/dev/null | head -1)
  [ -n "$zip" ] && ok "$(basename "$zip") ($(du -h "$zip" | cut -f1))" || { bad "no zip was made"; return; }
  rm -rf "$WORK/rel"; mkdir -p "$WORK/rel"; unzip -q -o "$zip" -d "$WORK/rel"
  local d; d="$WORK/rel/$(ls "$WORK/rel" | head -1)"
  [ -d "$d/FreeFlow.app" ] && [ -x "$d/install.sh" ] && [ -f "$d/README.md" ] && ok "the zip holds the app, install.sh and the README" || bad "the zip is missing a part"
  codesign --verify --deep --strict "$d/FreeFlow.app" >/dev/null 2>&1 && ok "the unzipped app's signature is intact" || bad "the unzipped app's signature is broken"
  local n; n=$("$d/FreeFlow.app/Contents/MacOS/FreeFlow" --test 2>&1 | grep -c '^ok')
  [ "$n" -ge 200 ] && ok "the unzipped copy passes its own $n unit checks" || bad "the unzipped copy's unit checks: $n ok"
  bash -n "$d/install.sh" && ok "install.sh is valid bash" || bad "install.sh has a syntax error"
  grep -q "xattr" "$d/install.sh" && ok "install.sh removes the download quarantine flag (the app is not notarised)" || bad "install.sh does not clear the quarantine flag"
  if spctl --assess --type execute "$d/FreeFlow.app" >/dev/null 2>&1; then ok "macOS Gatekeeper accepts the app as is"; else skp "Gatekeeper rejects the app as downloaded (signed with a development certificate, not notarised): teammates run install.sh"; fi
}

live_all() {
  stage "Live setup"
  if cmp -s "$BIN" "$APPBIN"; then ok "the installed app is the build under test"; else bad "the installed app differs from build/ (run ./build.sh install)"; fi
  prepare_voice
  snapshot_data
  trap 'restore_data' EXIT
  defaults write $DOM debugTriggers -bool true
  defaults write $DOM workdayInterval -float 1
  relaunch_app
  local pid0; pid0=$(pgrep -x FreeFlow | head -1)
  [ -n "$pid0" ] && ok "FreeFlow is running (pid $pid0), speech engine answers" || { bad "FreeFlow did not start"; return; }
  post gesture:one          # the tests start from one-tap dictation whatever the saved preference is; the preference is restored at the end
  local start; start=$(date +%s)
  # ONLY="live_typing live_notes" scripts/smoke.sh live   runs just those stages (the setup above always runs)
  for st in live_ui live_workday live_voice live_unsent live_typing live_detail live_notes live_calls live_mic live_browsers; do
    if [ -z "${ONLY:-}" ] || case " $ONLY " in *" $st "*) true ;; *) false ;; esac; then $st; fi
  done
  local pid1; pid1=$(pgrep -x FreeFlow | head -1)
  [ "$pid0" = "$pid1" ] && ok "the app never restarted or crashed during the run" || bad "the app restarted (pid $pid0 to $pid1)"
  if [ -z "${ONLY:-}" ] || case " $ONLY " in *" live_ui "*) true ;; *) false ;; esac; then live_follow_mac; fi          # restarts the app on purpose, so it comes after the check above
  if ls -t "$HOME/Library/Logs/DiagnosticReports"/FreeFlow* 2>/dev/null | head -1 | while read f; do [ "$(stat -f %m "$f")" -ge "$start" ] && exit 1; exit 0; done; then ok "no crash report was written"; else bad "a crash report was written during the run"; fi
}

# ---------------------------------------------------------------- run

case "$MODE" in
  static) stage_build; stage_units; stage_scripts; stage_voices; stage_system; stage_render; stage_release ;;
  live)   live_all ;;
  all)    stage_build; stage_units; stage_scripts; stage_voices; stage_system; stage_render; stage_release
          stage "Install"; if ./build.sh install >"$WORK/install.log" 2>&1; then ok "build installed and launched"; else bad "install"; fi
          live_all ;;
  *) echo "usage: scripts/smoke.sh [static|live|all]"; exit 2 ;;
esac

echo
echo "== Result: $pass ok, $fail failed, $skip skipped   (work files: $WORK)"
if [ $fail -gt 0 ]; then echo "Failed:$FAILED"; exit 1; fi
echo "SMOKE GREEN"
