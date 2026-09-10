#!/bin/zsh
# Real files and the production loop; only Arq and notification I/O are fake.
set -eu
unsetopt bg_nice
readonly SOURCE_SCRIPT="${0:A:h:h}/arq-gfn-guard.sh"
readonly TEST_ROOT="$(mktemp -d /tmp/arq-gfn-sources.XXXXXX)"
monitor_pid=""
trap '[[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
readonly FIXTURE_HOME="$TEST_ROOT/home"
readonly GFN_DIR="$FIXTURE_HOME/Library/Application Support/NVIDIA/GeForceNOW"
readonly STATE_DIR="$TEST_ROOT/state"
readonly CALLS="$TEST_ROOT/arqc.calls"
readonly ALERTS="$TEST_ROOT/alerts.calls"
mkdir -p "$GFN_DIR" "$STATE_DIR"
cat > "$TEST_ROOT/arqc" <<'SH'
#!/bin/zsh
print -r -- "$*" >> "$TEST_ARQC_CALLS"
exit "${TEST_ARQC_EXIT:-0}"
SH
cat > "$TEST_ROOT/osascript" <<'SH'
#!/bin/zsh
print -r -- "$*" >> "$TEST_ALERT_CALLS"
SH
chmod +x "$TEST_ROOT/arqc" "$TEST_ROOT/osascript"
sed "s#/usr/bin/osascript#$TEST_ROOT/osascript#g" "$SOURCE_SCRIPT" > "$TEST_ROOT/guard"
chmod +x "$TEST_ROOT/guard"
export TEST_ARQC_CALLS="$CALLS" TEST_ALERT_CALLS="$ALERTS"

debug_event() {
  print -r -- "[6588:259:2026-09-09/ 23:00:$1.000:INFO:gfn_background_agent_ipc.cpp(29)] Sending 'IPC_STREAMING_${2}_EVENT' to BackgroundAgent"
}
console_event() {
  print -r -- "2026-09-09 23:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"
}
run_once() {
  env HOME="$FIXTURE_HOME" ARQ_GFN_ARQC="$TEST_ROOT/arqc" \
    ARQ_GFN_FORCE_PROCESS="${TEST_PROCESS:-1}" ARQ_GFN_STATE_DIR="$STATE_DIR" \
    ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" ARQ_GFN_NOW="$1" \
    ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_LANG=en ARQ_GFN_ALERT_DELAY_SECONDS=1 \
    ARQ_GFN_GUARD_ONCE=1 "${TEST_GUARD:-$TEST_ROOT/guard}"
}
assert_owned() { [[ -f "$STATE_DIR/guard-paused" ]] || { print -u2 'Expected owned pause'; exit 1; }; }
assert_resumed() { [[ ! -f "$STATE_DIR/guard-paused" ]] || { print -u2 'Expected resumed backups'; exit 1; }; }

# debug-only source must pause; older console end must not override it.
debug_event 10 STARTED > "$GFN_DIR/debug.log"
console_event 01 Done > "$GFN_DIR/console.log"
run_once 10000
assert_owned
# Removing the current source must not expose an old end as the current one.
mv "$GFN_DIR/debug.log" "$TEST_ROOT/removed-debug"
run_once 10001
assert_owned
run_once 10002
assert_owned
mv "$TEST_ROOT/removed-debug" "$GFN_DIR/debug.log"
debug_event 20 TERMINATED >> "$GFN_DIR/debug.log"
run_once 10010
assert_resumed

# A stale but readable debug file cannot mask a newer console session.
console_event 30 Streaming >> "$GFN_DIR/console.log"
run_once 10020
assert_owned
console_event 40 Done >> "$GFN_DIR/console.log"
run_once 10030
assert_resumed

# Deleting the preferred file must keep detecting through the alternate.
rm "$GFN_DIR/debug.log"
console_event 50 Streaming >> "$GFN_DIR/console.log"
run_once 10040
assert_owned
console_event 59 Done >> "$GFN_DIR/console.log"
run_once 10050
assert_resumed

# Missing sources warn once after grace, including across restarts.
rm "$GFN_DIR/console.log"
: > "$ALERTS"
run_once 10100
[[ ! -s "$ALERTS" ]]
run_once 10102
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]]
run_once 10110
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]]

# An authoritative inactive state clears the episode without a false alarm.
debug_event 59 TERMINATED > "$GFN_DIR/debug.log"
run_once 10120
assert_resumed
rm "$GFN_DIR/debug.log"
run_once 10130
run_once 10132
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 2 ]]

# A known session plus failed Arq command warns despite normal notices off.
debug_event 59 STARTED > "$GFN_DIR/debug.log"
: > "$ALERTS"
TEST_ARQC_EXIT=42 run_once 10200
assert_resumed
[[ -s "$ALERTS" ]]
TEST_ARQC_EXIT=42 run_once 10210
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]]
run_once 10220
assert_owned
debug_event 59 TERMINATED >> "$GFN_DIR/debug.log"
: > "$ALERTS"
TEST_ARQC_EXIT=42 run_once 10230
assert_owned
[[ -s "$ALERTS" ]]
TEST_ARQC_EXIT=42 run_once 10231
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]]
run_once 10240
assert_resumed
debug_event 59 STARTED >> "$GFN_DIR/debug.log"
run_once 10250
assert_owned

# Deleting every source during a known session must retain ownership and warn.
rm "$GFN_DIR/debug.log"
: > "$ALERTS"
run_once 10300
assert_owned
run_once 10302
assert_owned
[[ -s "$ALERTS" ]]
TEST_PROCESS=0 run_once 10310
assert_resumed

# A nonempty but unrecognized log is not proof of an idle launcher.
print 'application initialized; no session events' > "$GFN_DIR/debug.log"
: > "$ALERTS"
run_once 10400
run_once 10402
[[ -s "$ALERTS" ]]

# Explicit overrides never silently inspect the real/default alternatives.
debug_event 59 STARTED > "$GFN_DIR/debug.log"
console_event 59 Done > "$TEST_ROOT/override.log"
ARQ_GFN_LOG_FILE="$TEST_ROOT/override.log" run_once 10500
assert_resumed

# Reject IPC-looking text from an unrelated module.
print "[6588:259:2026-09-09/ 23:00:59.000:INFO:other.cpp(29)] Sending 'IPC_STREAMING_STARTED_EVENT' to BackgroundAgent" > "$TEST_ROOT/override.log"
ARQ_GFN_LOG_FILE="$TEST_ROOT/override.log" run_once 10510
assert_resumed

# Alert opt-out and input validation do not alter ordinary pause behavior.
: > "$ALERTS"
ARQ_GFN_ERROR_NOTIFICATIONS=0 TEST_ARQC_EXIT=42 run_once 10600
[[ ! -s "$ALERTS" ]]
if ARQ_GFN_ERROR_NOTIFICATIONS=invalid run_once 10610 >/dev/null 2>&1; then
  print -u2 'Invalid error-notification option accepted'; exit 1
fi

# The long-running loop must notice alternate changes without a restart or
# waiting for the safety interval; a recreated primary must work afterwards.
# An authenticated rotated end must win over an unrelated older alternate.
debug_event 10 STARTED > "$GFN_DIR/debug.log"
console_event 01 Done > "$GFN_DIR/console.log"
run_once 11000
assert_owned
debug_event 20 TERMINATED >> "$GFN_DIR/debug.log"
mv "$GFN_DIR/debug.log" "$GFN_DIR/debug.log.bak"
print 'new debug generation' > "$GFN_DIR/debug.log"
run_once 11010
assert_resumed

# Recovering a rotated start must retain its time through renewal/restart.
rm "$GFN_DIR/console.log"
debug_event 10 STARTED > "$GFN_DIR/debug.log"
run_once 11200
assert_owned
mv -f "$GFN_DIR/debug.log" "$GFN_DIR/debug.log.bak"
print 'next debug generation' > "$GFN_DIR/debug.log"
run_once 11450
assert_owned
console_event 01 Done > "$GFN_DIR/console.log"
run_once 11460
assert_owned
debug_event 20 TERMINATED > "$GFN_DIR/debug.log"
run_once 11470
assert_resumed

# Upgrades from source-v1 lack a timestamp: an unrelated alternate end is
# not sufficient evidence to end the already-owned pause.
debug_event 30 STARTED > "$GFN_DIR/debug.log"
run_once 11480
assert_owned
python3.11 - "$STATE_DIR/guard-paused" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
epoch, header, checkpoints = p.read_bytes().split(b'\n', 2)
fields = header.split()
p.write_bytes(epoch + b'\nsource-v1 ' + fields[2] + b' ' + fields[3] + b'\n' + checkpoints)
PY
mv -f "$GFN_DIR/debug.log" "$GFN_DIR/debug.log.bak"
print 'new debug generation' > "$GFN_DIR/debug.log"
run_once 11481
assert_owned
TEST_PROCESS=0 run_once 11482
assert_resumed

# Fail only the external creation of the ownership temp file. The real
# write_state_timestamp error path must warn immediately after Arq succeeds.
cat > "$TEST_ROOT/mktemp" <<'SH'
#!/bin/zsh
[[ "$1" != *'.guard-paused.'* ]] || exit 1
exec /usr/bin/mktemp "$@"
SH
chmod +x "$TEST_ROOT/mktemp"
sed "s#/usr/bin/mktemp#$TEST_ROOT/mktemp#g" "$TEST_ROOT/guard" > "$TEST_ROOT/state-failure-guard"
chmod +x "$TEST_ROOT/state-failure-guard"
debug_event 30 STARTED >> "$GFN_DIR/debug.log"
: > "$ALERTS"
TEST_GUARD="$TEST_ROOT/state-failure-guard" run_once 11500
assert_resumed
[[ -s "$ALERTS" ]]

: > "$CALLS"
debug_event 10 STARTED > "$GFN_DIR/debug.log"
console_event 01 Done > "$GFN_DIR/console.log"
env HOME="$FIXTURE_HOME" ARQ_GFN_ARQC="$TEST_ROOT/arqc" \
  ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_STATE_DIR="$TEST_ROOT/live-state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/live.log" ARQ_GFN_NOTIFICATIONS=0 \
  ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_LOOP_SECONDS=1 \
  ARQ_GFN_SAFETY_SECONDS=120 "$TEST_ROOT/guard" &
monitor_pid=$!
wait_call() {
  local expected="$1" attempt
  for attempt in {1..60}; do
    if grep -Fq "$expected" "$CALLS"; then return 0; fi
    sleep 0.1
  done
  print -u2 "Missing live action: $expected"; exit 1
}
wait_call 'pauseBackups 10'
: > "$CALLS"
print 'ordinary debug append' >> "$GFN_DIR/debug.log"
sleep 2
rm "$GFN_DIR/debug.log"
sleep 2
if grep -Fq resumeBackups "$CALLS"; then
  print -u2 'Ordinary append lost the active event timestamp'; exit 1
fi
console_event 20 Done >> "$GFN_DIR/console.log"
wait_call resumeBackups
: > "$CALLS"
debug_event 30 STARTED > "$GFN_DIR/debug.log"
wait_call 'pauseBackups 10'
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""

# A large unseen burst in the nonselected source must not leave selection
# stuck on the alternate's older end. This also exercises recovery caching.
: > "$CALLS"
debug_event 10 TERMINATED > "$GFN_DIR/debug.log"
console_event 20 Done > "$GFN_DIR/console.log"
env HOME="$FIXTURE_HOME" ARQ_GFN_ARQC="$TEST_ROOT/arqc" \
  ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_STATE_DIR="$TEST_ROOT/burst-state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/burst.log" ARQ_GFN_NOTIFICATIONS=0 \
  ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_LOOP_SECONDS=1 \
  ARQ_GFN_SAFETY_SECONDS=2 "$TEST_ROOT/guard" &
monitor_pid=$!
sleep 2
debug_event 30 STARTED >> "$GFN_DIR/debug.log"
python3.11 - "$GFN_DIR/debug.log" <<'PY'
from pathlib import Path
import sys
with Path(sys.argv[1]).open('ab') as f:
    f.write(b'unrelated diagnostic entry\n' * 50000)
PY
wait_call 'pauseBackups 10'
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""

# Same-size/mtime rewrites of a nonselected source must be noticed at safety
# reconciliation, even though the other source's old end remains unchanged.
: > "$CALLS"
debug_event 10 STARTED > "$GFN_DIR/debug.log"
console_event 20 Done > "$GFN_DIR/console.log"
cp -p "$GFN_DIR/debug.log" "$TEST_ROOT/mtime-reference"
env HOME="$FIXTURE_HOME" ARQ_GFN_ARQC="$TEST_ROOT/arqc" \
  ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_STATE_DIR="$TEST_ROOT/rewrite-state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/rewrite.log" ARQ_GFN_NOTIFICATIONS=0 \
  ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_LOOP_SECONDS=1 \
  ARQ_GFN_SAFETY_SECONDS=2 "$TEST_ROOT/guard" &
monitor_pid=$!
sleep 2
debug_event 30 STARTED > "$GFN_DIR/debug.log"
touch -r "$TEST_ROOT/mtime-reference" "$GFN_DIR/debug.log"
wait_call 'pauseBackups 10'
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""

print 'All source selection and alert tests passed'
