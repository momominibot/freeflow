#!/bin/bash
# Runs the whole smoke test while you are away.
#
# The live part of scripts/smoke.sh takes over the keyboard and the focus for about 25 minutes (it types into TextEdit, opens a test
# browser, plays speech through the speakers). This waits until the Mac has had no keyboard or mouse use for a few minutes and is
# not locked, then runs it, and gives up at a set hour so it never starts in the middle of your morning.
#
#   scripts/smoke-when-idle.sh [MODE]        MODE is all (default), live or static
#   environment:  IDLE_MIN=5        minutes without keyboard or mouse before it starts
#                 GIVE_UP_HOUR=6    local hour after which it does not start (0 to 23)
#                 LOGFILE=...       default ~/Library/Logs/FreeFlow/smoke-DATE.log
#
# It writes LOGFILE and LOGFILE.result (one line: GREEN, FAILED with the failed checks, or NOT RUN with why). Exit 0 only when green.
# It changes no setting, and it does not unlock the screen: a locked Mac means it keeps waiting.

cd "$(dirname "$0")/.." || exit 2
MODE=${1:-all}
IDLE_MIN=${IDLE_MIN:-5}
GIVE_UP_HOUR=${GIVE_UP_HOUR:-6}
LOGFILE=${LOGFILE:-$HOME/Library/Logs/FreeFlow/smoke-$(date +%F).log}
mkdir -p "$(dirname "$LOGFILE")"
RESULT="$LOGFILE.result"
rm -f "$RESULT"

idle_seconds() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
locked() { ioreg -n Root -d1 2>/dev/null | grep -q '"IOConsoleLocked" = Yes'; }
# the next time the clock reads GIVE_UP_HOUR:00 (DEADLINE_EPOCH overrides it, for testing)
if [ -z "${DEADLINE_EPOCH:-}" ]; then
  DEADLINE_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%F) $(printf %02d "$GIVE_UP_HOUR"):00:00" +%s)
  [ "$DEADLINE_EPOCH" -le "$(date +%s)" ] && DEADLINE_EPOCH=$((DEADLINE_EPOCH + 86400))
fi
past_deadline() { [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; }

echo "waiting for $IDLE_MIN idle minutes (gives up at ${GIVE_UP_HOUR}:00) - $(date)" | tee -a "$LOGFILE"
# keep the Mac awake while waiting and running, without changing any setting (it ends with this script)
caffeinate -dims -w $$ >/dev/null 2>&1 &
while :; do
  if past_deadline; then
    echo "NOT RUN: you were still using the Mac, or it stayed locked, until ${GIVE_UP_HOUR}:00 ($(date))" | tee "$RESULT" | tee -a "$LOGFILE"
    exit 3
  fi
  if ! locked && [ "$(idle_seconds)" -ge $((IDLE_MIN * 60)) ]; then break; fi
  sleep 30
done

echo "starting $(date)" | tee -a "$LOGFILE"
scripts/smoke.sh "$MODE" >> "$LOGFILE" 2>&1
code=$?
if [ $code -eq 0 ]; then
  echo "GREEN: $(grep -E '^== Result' "$LOGFILE" | tail -1) ($(date))" > "$RESULT"
else
  { echo "FAILED: $(grep -E '^== Result' "$LOGFILE" | tail -1)"; sed -n '/^Failed:/,$p' "$LOGFILE" | tail -12; } > "$RESULT"
fi
cat "$RESULT"
exit $code
