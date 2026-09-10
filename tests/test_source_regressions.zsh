#!/bin/zsh
# Regression coverage for retained alternate evidence, rollback ordering, and
# retryable full scans. These tests use the production parser and selector.
set -eu
unsetopt bg_nice

readonly GUARD="${0:A:h:h}/arq-gfn-guard.sh"
readonly ROOT="$(mktemp -d /tmp/arq-gfn-regressions.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

event() {
  print -r -- "2026-09-10 $1 INFO gfn/StreamerManagerService  Advancing to state: $2" >> "$3"
}

run_guard() {
  env HOME="$HOME" ARQ_GFN_ARQC="$ARQ_GFN_ARQC" ARQ_GFN_STATE_DIR="$ARQ_GFN_STATE_DIR" \
    ARQ_GFN_GUARD_LOG="$ARQ_GFN_GUARD_LOG" ARQ_GFN_FORCE_PROCESS="${TEST_PROCESS:-1}" \
    ARQ_GFN_NOW="$1" ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0 \
    ARQ_GFN_GUARD_ONCE=1 "$GUARD"
}

new_fixture() {
  local name="$1"
  TEST_HOME="$ROOT/$name/home"
  TEST_LOGS="$TEST_HOME/Library/Application Support/NVIDIA/GeForceNOW"
  TEST_STATE="$ROOT/$name/state"
  TEST_ACTIONS="$ROOT/$name/actions"
  mkdir -p "$TEST_LOGS" "$TEST_STATE"
  print -r -- '#!/bin/zsh' > "$ROOT/$name/arqc"
  print -r -- 'print -r -- "$*" >> "$ARQ_TEST_ACTIONS"' >> "$ROOT/$name/arqc"
  chmod 700 "$ROOT/$name/arqc"
  export HOME="$TEST_HOME" ARQ_GFN_STATE_DIR="$TEST_STATE" \
    ARQ_GFN_GUARD_LOG="$ROOT/$name/guard.log" ARQ_GFN_ARQC="$ROOT/$name/arqc" \
    ARQ_TEST_ACTIONS="$TEST_ACTIONS"
  : > "$TEST_ACTIONS"
}

check() { "$@" || { print -u2 -- "FAIL: $*"; exit 1; }; }

# An older inactive alternate must remain rejected after a noise append, while
# a genuinely newer end is still accepted.
new_fixture stale
event 11:00:00.000 Streaming "$TEST_LOGS/debug.log"
event 10:00:00.000 Done "$TEST_LOGS/console.log"
run_guard 1000
check test -f "$TEST_STATE/guard-paused"
mv "$TEST_LOGS/debug.log" "$ROOT/stale-debug.log"
run_guard 1010
check test -f "$TEST_STATE/guard-paused"
run_guard 1250
check grep -Eq '^source-v[34] debug ' "$TEST_STATE/guard-paused"
print -r -- noise >> "$TEST_LOGS/console.log"
run_guard 1260
check test -f "$TEST_STATE/guard-paused"
if grep -q '^resumeBackups$' "$TEST_ACTIONS"; then
  print -u2 -- 'FAIL: stale alternate inactive resumed Arq after noise'; exit 1
fi
event 12:00:00.000 Done "$TEST_LOGS/console.log"
run_guard 1300
check test ! -f "$TEST_STATE/guard-paused"
check grep -q '^resumeBackups$' "$TEST_ACTIONS"

# A stopped process baseline must survive a guard restart and suppress the
# previous process's unchanged active marker until a new lifecycle event.
new_fixture post-exit
event 11:00:00.000 Streaming "$TEST_LOGS/debug.log"
run_guard 3000
check test -f "$TEST_STATE/guard-paused"
TEST_PROCESS=0 run_guard 3010
check test ! -f "$TEST_STATE/guard-paused"
check test -f "$TEST_STATE/guard-stopped"
: > "$TEST_ACTIONS"
run_guard 3250
check test ! -f "$TEST_STATE/guard-paused"
if grep -q '^pauseBackups' "$TEST_ACTIONS"; then
  print -u2 -- 'FAIL: unchanged pre-exit active marker renewed after restart'; exit 1
fi
event 12:00:00.000 Streaming "$TEST_LOGS/debug.log"
run_guard 3260
check test -f "$TEST_STATE/guard-paused"
check test ! -f "$TEST_STATE/guard-stopped"

# Load definitions without starting the production loop so both candidate
# scans happen in the same selector pass and rollback resolution is observable.
run_selector_case() (
  local name="$1" debug_next="$2" console_next="$3" expected_source="$4" expected_state="$5"
  local root="$ROOT/$name"
  mkdir -p "$root/home/Library/Application Support/NVIDIA/GeForceNOW" "$root/state"
  export HOME="$root/home" ARQ_GFN_STATE_DIR="$root/state" \
    ARQ_GFN_GUARD_LOG="$root/guard.log" ARQ_GFN_ARQC="$root/arqc" \
    ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0 \
    ARQ_GFN_LANG=en ARQ_GFN_NOW=1000
  print -r -- '#!/bin/zsh' > "$root/arqc"
  print -r -- 'print -r -- "$*" >> "$ARQ_TEST_ACTIONS"' >> "$root/arqc"
  chmod 700 "$root/arqc"
  export ARQ_TEST_ACTIONS="$root/actions"
  : > "$ARQ_TEST_ACTIONS"
  source <(/usr/bin/awk '/^restore_source_checkpoint \|\| true$/ { exit } { print }' "$GUARD")
  event 12:00:00.000 Streaming "$GFN_DEBUG_LOG"
  event 12:00:00.000 Streaming "$GFN_CONSOLE_LOG"
  select_log_source
  reconcile_backup_state 1000 "$selected_signature_out"
  event 11:01:00.000 "$debug_next" "$GFN_DEBUG_LOG"
  event 11:01:00.000 "$console_next" "$GFN_CONSOLE_LOG"
  select_log_source
  check test "$GFN_LOG_SOURCE_KEY" = "$expected_source"
  check test "$clock_source_key" = "$expected_source"
  reconcile_backup_state 1100 "$selected_signature_out"
  check test "$detected_stream_state_out" = "$expected_state"
  if [[ "$expected_state" == active ]]; then
    if grep -q '^resumeBackups$' "$ARQ_TEST_ACTIONS"; then
      print -u2 -- 'FAIL: equal-time active rollback lost to inactive'; exit 1
    fi
  else
    check grep -q '^resumeBackups$' "$ARQ_TEST_ACTIONS"
  fi
)

run_selector_case rollback-debug-active Streaming Done debug active
run_selector_case rollback-console-active Done Streaming console active
run_selector_case rollback-debug-end Done Streaming console active
run_selector_case rollback-console-end Streaming Done debug active

# The source-switch guard is symmetric: an older active marker from the
# alternate file must not resurrect a session already proven inactive.
run_inactive_switch_case() (
  root="$ROOT/stale-active"
  mkdir -p "$root/home/Library/Application Support/NVIDIA/GeForceNOW" "$root/state"
  export HOME="$root/home" ARQ_GFN_STATE_DIR="$root/state" ARQ_GFN_GUARD_LOG="$root/guard.log" \
    ARQ_GFN_ARQC="$root/arqc" ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 \
    ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_LANG=en ARQ_TEST_ACTIONS="$root/actions"
  print -r -- '#!/bin/zsh' > "$root/arqc"
  print -r -- 'print -r -- "$*" >> "$ARQ_TEST_ACTIONS"' >> "$root/arqc"
  chmod 700 "$root/arqc"
  : > "$ARQ_TEST_ACTIONS"
  source <(/usr/bin/awk '/^restore_source_checkpoint \|\| true$/ { exit } { print }' "$GUARD")
  event 11:00:00.000 Done "$GFN_DEBUG_LOG"
  select_log_source
  reconcile_backup_state 2000 "$selected_signature_out"
  event 10:00:00.000 Streaming "$GFN_CONSOLE_LOG"
  mv "$GFN_DEBUG_LOG" "$root/debug.log.removed"
  select_log_source
  reconcile_backup_state 2010 "$selected_signature_out"
  if grep -q '^pauseBackups' "$ARQ_TEST_ACTIONS"; then
    print -u2 -- 'FAIL: stale alternate active marker paused Arq after inactive proof'
    exit 1
  fi
)
run_inactive_switch_case

# A transient full-scan error must not poison parsed state; an unchanged file
# is retried and the successful scan establishes the active lease.
(
  root="$ROOT/retry"
  mkdir -p "$root/home/Library/Application Support/NVIDIA/GeForceNOW" "$root/state"
  export HOME="$root/home" ARQ_GFN_STATE_DIR="$root/state" ARQ_GFN_GUARD_LOG="$root/guard.log" \
    ARQ_GFN_ARQC="$root/arqc" ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 \
    ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_LANG=en ARQ_TEST_ACTIONS="$root/actions"
  print -r -- '#!/bin/zsh' > "$root/arqc"
  print -r -- 'print -r -- "$*" >> "$ARQ_TEST_ACTIONS"' >> "$root/arqc"
  chmod 700 "$root/arqc"
  : > "$ARQ_TEST_ACTIONS"
  source <(/usr/bin/awk '/^restore_source_checkpoint \|\| true$/ { exit } { print }' "$GUARD")
  event 10:00:00.000 Streaming "$GFN_DEBUG_LOG"
  /usr/bin/awk 'BEGIN { for (i = 1; i <= 120000; i++) print "diagnostic noise" }' >> "$GFN_DEBUG_LOG"
  functions[real_parse_stream_evidence]="${functions[parse_stream_evidence]}"
  parse_stream_evidence() {
    if [[ "${1:-}" == "$GFN_DEBUG_LOG" && -f "$root/fail-once" ]]; then
      rm -f "$root/fail-once"
      return 1
    fi
    real_parse_stream_evidence "$@"
  }
  : > "$root/fail-once"
  select_log_source
  check test "$selected_source_evidence_invalid" = 1
  check test -z "$parsed_signature"
  local signature="$selected_signature_out"
  select_log_source
  check test "$selected_signature_out" = "$signature"
  check test "$selected_source_evidence_invalid" = 0
  reconcile_backup_state 1100 "$selected_signature_out"
  check test "$detected_stream_state_out" = active
  check test -f "$STATE_DIR/guard-paused"
)

print -r -- 'All source regression tests passed'
