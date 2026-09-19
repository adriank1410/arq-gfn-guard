#!/bin/zsh
# Clock metadata and owned lease proof must agree across an independent
# restart. Only Arq and notification boundaries are substituted.
set -eu
unsetopt bg_nice

readonly GUARD_SOURCE="${0:A:h:h}/arq-gfn-guard.sh"
readonly TEST_ROOT="$(mktemp -d /tmp/arq-gfn-clock.XXXXXX)"
readonly LOG_DIR="$TEST_ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
readonly STATE_DIR="$TEST_ROOT/state"
readonly CALLS="$TEST_ROOT/arqc.calls"
readonly ALERTS="$TEST_ROOT/alerts"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$LOG_DIR" "$STATE_DIR"

print -r -- '#!/bin/zsh' > "$TEST_ROOT/arqc"
print -r -- 'print -r -- "$*" >> "$TEST_ARQC_CALLS"' >> "$TEST_ROOT/arqc"
print -r -- 'exit "${TEST_ARQC_EXIT:-0}"' >> "$TEST_ROOT/arqc"
print -r -- '#!/bin/zsh' > "$TEST_ROOT/osascript"
print -r -- 'print -r -- "$*" >> "$TEST_ALERT_CALLS"' >> "$TEST_ROOT/osascript"
chmod +x "$TEST_ROOT/arqc" "$TEST_ROOT/osascript"
sed "s#/usr/bin/osascript#$TEST_ROOT/osascript#g" "$GUARD_SOURCE" > "$TEST_ROOT/guard"
chmod +x "$TEST_ROOT/guard"
export TEST_ARQC_CALLS="$CALLS" TEST_ALERT_CALLS="$ALERTS"

debug_event() {
  print -r -- "2026-09-10 00:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"
}
console_event() {
  print -r -- "2026-09-10 00:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"
}
run_once() {
  env HOME="$TEST_ROOT/home" ARQ_GFN_ARQC="$TEST_ROOT/arqc" \
    ARQ_GFN_STATE_DIR="$STATE_DIR" ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
    ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOW="$1" ARQ_GFN_NOTIFICATIONS=0 \
    ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_GUARD_ONCE=1 "$TEST_ROOT/guard"
}
clear_fixture() {
  rm -f "$STATE_DIR/guard-paused" "$STATE_DIR/guard-clock" \
    "$STATE_DIR/guard-alert" "$STATE_DIR/guard-alert-detection" \
    "$STATE_DIR/guard-alert-action" "$LOG_DIR/debug.log" "$LOG_DIR/console.log"
  : > "$CALLS"
}
write_owned_proof() {
  local version="$1"
  local source_key="$2"
  local revision="$3"
  local source_file="$4"
  local event_time="$5"
  local source_identity source_size
  source_identity="$(/usr/bin/stat -f '%d:%i' "$source_file")"
  source_size="$(wc -c < "$source_file" | tr -d ' ')"
  {
    print -r -- 100
    if [[ "$version" == source-v5 ]]; then
      print -r -- "source-v5 $source_key $source_identity $source_size $event_time $source_key $revision - - $source_identity"
    elif [[ "$version" == source-v4 ]]; then
      print -r -- "source-v4 $source_key $source_identity $source_size $event_time $source_key $revision - -"
    else
      print -r -- "source-v3 $source_key $source_identity $source_size $event_time $source_key"
    fi
    /bin/cat "$source_file"
    /bin/cat "$source_file"
  } > "$STATE_DIR/guard-paused"
}

# A newer source-v4 lease proof must win over an older independent clock
# snapshot. The old implementation restores the clock-v1 pin last and resumes
# from the stale debug end instead of preserving the new console session.
for proof_format in source-v4 source-v5; do
clear_fixture
debug_event 10 Done > "$LOG_DIR/debug.log"
console_event 20 Streaming > "$LOG_DIR/console.log"
write_owned_proof "$proof_format" console 1 "$LOG_DIR/console.log" 20260910000020000
print -r -- 'clock-v1 debug - -' > "$STATE_DIR/guard-clock"
run_once 1000
grep -Fq 'pauseBackups 10' "$CALLS" \
  || { print -u2 'Newer lease proof did not preserve the active console session'; exit 1; }
if grep -Fq 'resumeBackups' "$CALLS"; then
  print -u2 'Older clock snapshot resumed the active session'; exit 1
fi
done

# Conversely, a newer released clock snapshot must override an older pin
# after a failed resume and allow the newer debug end to win.
for proof_format in source-v3 source-v4 source-v5; do
clear_fixture
debug_event 30 Done > "$LOG_DIR/debug.log"
console_event 20 Streaming > "$LOG_DIR/console.log"
write_owned_proof "$proof_format" console 1 "$LOG_DIR/console.log" 20260910000020000
print -r -- 'clock-v2 2 - - -' > "$STATE_DIR/guard-clock"
run_once 2000
grep -Fq 'resumeBackups' "$CALLS" \
  || { print -u2 'Newer released clock snapshot did not override legacy lease pin'; exit 1; }
if grep -Fq 'pauseBackups 10' "$CALLS"; then
  print -u2 'Older lease pin overrode newer clock snapshot'; exit 1
fi
done

# Legacy source-v3 has no ordering number. Keep the historical rule that an
# independent clock record is authoritative when it is present.
clear_fixture
debug_event 30 Done > "$LOG_DIR/debug.log"
console_event 20 Streaming > "$LOG_DIR/console.log"
write_owned_proof source-v3 console 0 "$LOG_DIR/console.log" 20260910000020000
print -r -- 'clock-v1 - - -' > "$STATE_DIR/guard-clock"
run_once 3000
grep -Fq 'resumeBackups' "$CALLS" \
  || { print -u2 'Legacy independent clock did not override source-v3 pin'; exit 1; }

print -r -- 'All clock persistence tests passed'
