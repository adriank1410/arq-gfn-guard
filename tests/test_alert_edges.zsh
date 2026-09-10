#!/bin/zsh
# Alert slots must survive overlapping diagnostics and Arq-operation failures.
set -eu

readonly GUARD_SOURCE="${0:A:h:h}/arq-gfn-guard.sh"
readonly TEST_ROOT="$(mktemp -d /tmp/arq-gfn-alerts.XXXXXX)"
readonly LOG_FILE="$TEST_ROOT/gfn.log"
readonly STATE_DIR="$TEST_ROOT/state"
readonly ALERTS="$TEST_ROOT/alerts"
readonly CALLS="$TEST_ROOT/arqc.calls"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$STATE_DIR"

print -r -- '#!/bin/zsh' > "$TEST_ROOT/arqc"
print -r -- 'print -r -- "$*" >> "$TEST_ARQC_CALLS"' >> "$TEST_ROOT/arqc"
print -r -- 'exit "${TEST_ARQC_EXIT:-0}"' >> "$TEST_ROOT/arqc"
print -r -- '#!/bin/zsh' > "$TEST_ROOT/osascript"
print -r -- 'print -r -- "$*" >> "$TEST_ALERT_CALLS"' >> "$TEST_ROOT/osascript"
chmod +x "$TEST_ROOT/arqc" "$TEST_ROOT/osascript"
sed "s#/usr/bin/osascript#$TEST_ROOT/osascript#g" "$GUARD_SOURCE" > "$TEST_ROOT/guard"
chmod +x "$TEST_ROOT/guard"
export TEST_ARQC_CALLS="$CALLS" TEST_ALERT_CALLS="$ALERTS"

console_event() {
  print -r -- "2026-09-09 23:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"
}

run_once() {
  local now_epoch="$1"
  local delay_seconds="$2"
  env ARQ_GFN_ARQC="$TEST_ROOT/arqc" ARQ_GFN_LOG_FILE="$LOG_FILE" \
    ARQ_GFN_STATE_DIR="$STATE_DIR" ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
    ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOW="$now_epoch" \
    ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=1 \
    ARQ_GFN_LANG=en ARQ_GFN_ALERT_DELAY_SECONDS="$delay_seconds" \
    ARQ_GFN_GUARD_ONCE=1 "$TEST_ROOT/guard"
}

# Establish an owned active lease, then remove its only source. A successful
# renewal keeps the detection alert alive while preserving the owned lease.
console_event 10 Streaming > "$LOG_FILE"
run_once 10000 0
[[ -f "$STATE_DIR/guard-paused" ]] || { print -u2 'Expected owned lease'; exit 1; }
rm "$LOG_FILE"
: > "$ALERTS"
run_once 10250 0
[[ -f "$STATE_DIR/guard-alert-detection" ]] || { print -u2 'Missing detection slot'; exit 1; }
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] || { print -u2 'Expected one missing-log alert'; exit 1; }

# At the next renewal, Arq fails while the detection episode is still active.
# Both alerts are useful, and repeating the failed renewal must not alternate
# the one-slot state back to the detection alert on every restart.
: > "$ALERTS"
TEST_ARQC_EXIT=42 run_once 10500 0
[[ -f "$STATE_DIR/guard-alert-action" ]] || { print -u2 'Missing action slot'; exit 1; }
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] || { print -u2 'Expected one pause-failure alert'; exit 1; }
TEST_ARQC_EXIT=42 run_once 10501 0
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] || { print -u2 'Pause-failure alert was not deduplicated'; exit 1; }
[[ -f "$STATE_DIR/guard-alert-detection" ]] || { print -u2 'Detection episode was overwritten'; exit 1; }

# A clock rollback must restart the grace window. Otherwise a persisted future
# start would suppress the first alert until wall time caught up.
rm -f "$STATE_DIR/guard-paused" "$STATE_DIR/guard-alert-detection" "$STATE_DIR/guard-alert-action" "$STATE_DIR/guard-alert"
: > "$ALERTS"
run_once 5000 60
run_once 4990 60
run_once 5050 60
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] || { print -u2 'Clock rollback did not reset alert grace'; exit 1; }
run_once 5100 60
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] || { print -u2 'Persisted alert was not deduplicated'; exit 1; }

# Upgrade the earlier single-slot record without repeating its notification.
mv "$STATE_DIR/guard-alert-detection" "$STATE_DIR/guard-alert"
run_once 5110 60
[[ -f "$STATE_DIR/guard-alert-detection" && ! -f "$STATE_DIR/guard-alert" ]] \
 || { print -u2 'Legacy alert did not migrate'; exit 1; }
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 1 ]] \
 || { print -u2 'Legacy migration repeated notification'; exit 1; }

# Recovery clears persisted detection state and permits a new episode.
console_event 20 Done > "$LOG_FILE"
run_once 5120 60
[[ ! -f "$STATE_DIR/guard-alert-detection" ]] || { print -u2 'Recovery kept detection alert'; exit 1; }
rm "$LOG_FILE"
run_once 5130 0
[[ "$(wc -l < "$ALERTS" | tr -d ' ')" == 2 ]] || { print -u2 'New episode did not notify'; exit 1; }
print -r -- 'All alert edge tests passed' 
