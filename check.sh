#!/bin/bash
# pace's behavioural baseline.
#
#   ./check.sh          build, run the whole observable surface, diff it against
#                       baseline/. Exit 0 means nothing a user could notice changed.
#   ./check.sh --bless   re-record baseline/ from the current build. Only ever do
#                       this when you MEANT to change behaviour, and say so in the
#                       commit that carries the new baseline.
#
# Why this exists: pace has no unit tests and doesn't want any. What it has instead
# is four headless verbs that print exactly what the loop decided — `--selftest`,
# `--sim`, `--parse`, `--report-demo` — and those printouts are a far better oracle
# than assertions about internals, because they change when and only when the app's
# behaviour changes. Refactor freely; if this stays green you didn't break anything
# a person could see.
#
# What it cannot see: anything that draws. The menu bar, the break card, the popover,
# the stats window and the vault writes from the live app are all invisible here. A
# green run is permission to stop worrying about the loop, not about the UI.
set -u
cd "$(dirname "$0")" || exit 90

BASE="baseline"
BLESS=0
[ "${1:-}" = "--bless" ] && BLESS=1

BIN=".build/release/pace"
echo "--- building ---"
swift build -c release 2>&1 | grep -E "error:|warning:|Build complete" || true
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN"; exit 91; }

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

# Pinned so the sample fortnight doesn't rename itself every midnight. Any fixed
# date does; this is the day the baseline was first cut.
DEMO_DAY="2026-09-15"

echo "--- capturing ---"
{ "$BIN" --selftest; echo "exit: $?"; } > "$OUT/selftest.txt" 2>&1

i=0
while IFS= read -r s; do
  [ -z "$s" ] && continue
  i=$((i+1))
  { echo "### $s"; "$BIN" --sim "$s"; echo "exit: $?"; } > "$OUT/sim-$(printf %02d $i).txt" 2>&1
done <<'SCRIPTS'
eye 5m, moveoff, work 5m, snooze, work 5m, snooze, work 5m, snooze, work 5m, done, work 5m
eye 20m, move 30m, work 2h
eye 20m, moveoff, work 20m, done, work 20m, done, work 20m, skip, work 20m
eye 5m, moveoff, work 5m, skip, work 5m, skip, work 5m, done
eye 5m, move 10m, work 30m, done, work 30m
eye 5m, moveoff, call 30m, work 10m
eye 5m, moveoff, nudges, call 30m, work 10m
eye 5m, move 10m, nudges, call 2h, work 10m
eye 5m, moveoff, nudges, call 10m, interrupt, call 10m, work 10m
eye 5m, moveoff, work 4m, call 20m, work 10m
eye 5m, moveoff, lock 20m, work 10m
eye 5m, moveoff, lock 5m, work 10m
eye 5m, moveoff, lostunlock 30m, work 10m
eye 5m, moveoff, work 4m, lock 1h, work 10m
eye 5m, moveoff, pause 30m, work 10m
eye 5m, moveoff, work 4m, pause 10m, work 10m
eye 5m, move 10m, work 20m, interrupt, work 20m
eye 5m, move 10m, nudges, work 10m, call 1h, work 20m, done, work 20m
eyeoff, move 10m, work 40m, done, work 20m
eye 1m, move 2m, work 15m
eye 5m, moveoff, work 5m, snooze, lock 1h, work 10m
eye 5m, move 10m, nudges, call 45m, lock 30m, work 15m
eye 20m, moveoff, work 10m, eye 5m, work 2m
eye 5m, moveoff, work 6m, call 20m, work 10m
eye 5m, moveoff, work 6m, lock 30m, work 10m
eye 5m, moveoff, work 4m, lostunlock 30m, work 10m
eye 5m, moveoff, work 4m, pause 1m, work 3m
eye 5m, moveoff, nudges, work 4m, pause 30m, call 10m, work 10m
eye 5m, moveoff, nudges, work 5m, snooze, call 30m, work 10m
eyeoff, moveoff, work 10m, lock 30m, work 5m
eye 5m, moveoff, nudges, work 5m, call 30m, work 5m
eye 5m, moveoff, nudges, work 5m, call 4m, work 5m
eye 5m, moveoff, nudges, work 5m, call 10m, work 1m, call 10m, work 5m
eye 5m, move 10m, nudges, work 12m, call 45m, work 5m
SCRIPTS

{
while IFS= read -r p; do
  [ -z "$p" ] && continue
  printf '%-34s -> ' "$p"
  "$BIN" --parse "$p"
done <<'PHRASES'
25m
break in 10m
eye break in 5 minutes
move break at 3pm
@3pm
pause 1h
pause until 5pm
pause for 30 minutes
2h
in an hour
move in 45m
stretch at 14:30
eyes in 20
half an hour
tomorrow
banana
at 9
5s
0m
-10m
PHRASES
} > "$OUT/parse.txt" 2>&1

RD=$(mktemp -d)
"$BIN" --report-demo "$RD" "$DEMO_DAY" 2>&1 | sed "s#$RD#<TMP>#g" > "$OUT/report-demo.txt"
( cd "$RD" && find . -type f | sort ) >> "$OUT/report-demo.txt" 2>&1
{ echo "--- file contents ---"
  for f in $(cd "$RD" && find . -type f | sort); do echo "=== $f ==="; cat "$RD/$f"; done
} >> "$OUT/report-demo.txt" 2>&1
rm -rf "$RD"

if [ "$BLESS" = "1" ]; then
  rm -rf "$BASE"; mkdir -p "$BASE"; cp "$OUT"/* "$BASE/"
  echo "BLESSED: $BASE re-recorded from this build ($i sim scenarios). Commit it with the change that justified it."
  exit 0
fi

echo "--- diffing ---"
if diff -r "$BASE" "$OUT" > "$OUT.diff" 2>&1; then
  echo "PASS: behaviour unchanged ($i sim scenarios + selftest + parse + report)"
  exit 0
fi
echo "FAIL: behaviour differs from $BASE/"
head -80 "$OUT.diff"
echo
echo "If the change was deliberate: ./check.sh --bless, then commit baseline/ with it."
exit 93
