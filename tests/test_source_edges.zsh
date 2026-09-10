#!/bin/zsh
set -eu
unsetopt bg_nice
readonly REPO="${0:A:h:h}"
readonly ROOT="$(mktemp -d /tmp/arq-source-edges.XXXXXX)"
readonly LOGS="$ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
readonly EXPLICIT_LOG="$ROOT/explicit.log"
monitor_pid=""
trap '[[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
mkdir -p "$LOGS"
cat > "$ROOT/pgrep" <<'SH'
#!/bin/zsh
exit "$(cat "$TEST_PROCESS_FILE")"
SH
cat > "$ROOT/arqc" <<'SH'
#!/bin/zsh
print -r -- "$*" >> "$TEST_CALLS"
SH
chmod +x "$ROOT/pgrep" "$ROOT/arqc"
sed "s#/usr/bin/pgrep#$ROOT/pgrep#g" "$REPO/arq-gfn-guard.sh" > "$ROOT/guard"
chmod +x "$ROOT/guard"
export TEST_PROCESS_FILE="$ROOT/process" TEST_CALLS="$ROOT/calls"
print 0 > "$ROOT/process"
: > "$ROOT/calls"
debug_event() { print "[1:1:2026-09-09/ $1.000:INFO:gfn_background_agent_ipc.cpp(29)] Sending 'IPC_STREAMING_${2}_EVENT' to BackgroundAgent"; }
console_event() { print "2026-09-09 $1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"; }
start_guard() {
  env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_STATE_DIR="$ROOT/state" \
  ARQ_GFN_GUARD_LOG="$ROOT/guard.log" ARQ_GFN_LOOP_SECONDS=1 ARQ_GFN_SAFETY_SECONDS=1 \
  ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0 "$ROOT/guard" &
  monitor_pid=$!
}
start_explicit_guard() {
 env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_LOG_FILE="$EXPLICIT_LOG" \
 ARQ_GFN_STATE_DIR="$ROOT/state" ARQ_GFN_GUARD_LOG="$ROOT/explicit-guard.log" \
 ARQ_GFN_LOOP_SECONDS=1 ARQ_GFN_SAFETY_SECONDS=1 ARQ_GFN_NOTIFICATIONS=0 \
 ARQ_GFN_ERROR_NOTIFICATIONS=0 "$ROOT/guard" &
 monitor_pid=$!
}
stop_guard() { kill "$monitor_pid"; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; }
wait_call() {
 local attempt
 for attempt in {1..80}; do
  if grep -Fq "$1" "$ROOT/calls"; then
   # Wait for the complete guard operation, not just entry into fake arqc.
   if [[ "$1" == 'pauseBackups 10' && -f "$ROOT/state/guard-paused" ]] \
       || [[ "$1" == resumeBackups && ! -f "$ROOT/state/guard-paused" ]]; then return; fi
  fi
  sleep 0.1
 done
 print -u2 "Missing expected action: $1"; exit 1
}

# A previously nonselected console source rotates its NEW start into .bak.
debug_event 23:00:20 TERMINATED > "$LOGS/debug.log"
console_event 23:00:10 Done > "$LOGS/console.log"
start_guard
sleep 2
console_event 23:00:30 Streaming >> "$LOGS/console.log"
mv "$LOGS/console.log" "$LOGS/console.log.bak"
print 'new generation' > "$LOGS/console.log"
wait_call 'pauseBackups 10'

# Crash/exit followed by launcher-only reopening must not reuse old starts.
: > "$ROOT/calls"
print 1 > "$ROOT/process"
wait_call resumeBackups
: > "$ROOT/calls"
print 0 > "$ROOT/process"
print 'unrelated diagnostic entry' >> "$LOGS/console.log"
sleep 3
[[ ! -s "$ROOT/calls" ]] || { print -u2 'Pre-exit event paused reopened launcher'; exit 1; }
console_event 23:00:40 Streaming >> "$LOGS/console.log"
wait_call 'pauseBackups 10'
stop_guard

# Backward local timestamps during an observed append must not lose to a
# stale end in the other source, including while the owned guard restarts.
rm -f "$ROOT/state/guard-paused"
: > "$ROOT/calls"
debug_event 01:59:00 TERMINATED > "$LOGS/debug.log"
console_event 01:58:00 Done > "$LOGS/console.log"
start_guard
sleep 2
console_event 01:05:00 Streaming >> "$LOGS/console.log"
wait_call 'pauseBackups 10'
stop_guard
: > "$ROOT/calls"
start_guard
sleep 2
if grep -Fq resumeBackups "$ROOT/calls"; then print -u2 'Restart forgot clock rollback'; exit 1; fi
# The other file is still in the old clock epoch; losing the pinned source
# must retain the owned lease rather than accepting its stale end.
mv "$LOGS/console.log" "$LOGS/console.clock-test"
sleep 2
[[ -f "$ROOT/state/guard-paused" ]] || { print -u2 'Missing clock source ended lease'; exit 1; }
! grep -Fq resumeBackups "$ROOT/calls" || { print -u2 'Stale clock source resumed Arq'; exit 1; }
mv "$LOGS/console.clock-test" "$LOGS/console.log"
console_event 01:06:00 Done >> "$LOGS/console.log"
wait_call resumeBackups
stop_guard
# Rollback while a lease is already owned must persist the new source before
# the ordinary four-minute renewal is due, so a restart can still see its end.
: > "$ROOT/calls"
debug_event 02:59:00 STARTED > "$LOGS/debug.log"
console_event 02:58:00 Done > "$LOGS/console.log"
start_guard
wait_call 'pauseBackups 10'
console_event 02:05:00 Streaming >> "$LOGS/console.log"
for attempt in {1..80}; do
 if /usr/bin/sed -n '2p' "$ROOT/state/guard-paused" | grep -q ' console$'; then break; fi
 sleep 0.1
done
/usr/bin/sed -n '2p' "$ROOT/state/guard-paused" | grep -q ' console$' \
 || { print -u2 'Rollback source was not persisted before renewal'; exit 1; }
stop_guard
: > "$ROOT/calls"
start_guard
console_event 02:06:00 Done >> "$LOGS/console.log"
wait_call resumeBackups
stop_guard

# A candidate source may disappear for a poll while the other source becomes
# selected. Its own checkpoints must survive that gap so a later marker-free
# replacement can still authenticate an end in source.bak.
rm -f "$LOGS"/debug.log "$LOGS"/debug.log.bak "$LOGS"/console.log "$LOGS"/console.log.bak \
  "$ROOT/state"/guard-paused "$ROOT/state/guard-alert" \
  "$ROOT/state/guard-alert-detection" "$ROOT/state/guard-alert-action" "$ROOT/calls"
: > "$ROOT/calls"
print 0 > "$ROOT/process"
debug_event 03:00:10 STARTED > "$LOGS/debug.log"
console_event 03:00:01 Done > "$LOGS/console.log"
start_guard
wait_call 'pauseBackups 10'
: > "$ROOT/calls"
mv "$LOGS/debug.log" "$LOGS/debug.log.bak"
sleep 2
debug_event 03:00:20 TERMINATED >> "$LOGS/debug.log.bak"
print 'new debug generation' > "$LOGS/debug.log"
wait_call resumeBackups
stop_guard

# An explicit source with only unrelated post-exit appends must not replay its
# pre-exit active event after its stat signature changes.
rm -f "$LOGS"/debug.log "$LOGS"/debug.log.bak "$LOGS"/console.log "$LOGS"/console.log.bak \
  "$ROOT/state"/guard-paused "$ROOT/state/guard-alert" \
  "$ROOT/state/guard-alert-detection" "$ROOT/state/guard-alert-action" "$EXPLICIT_LOG"
: > "$ROOT/calls"
print 0 > "$ROOT/process"
console_event 03:30:10 Streaming > "$EXPLICIT_LOG"
start_explicit_guard
wait_call 'pauseBackups 10'
: > "$ROOT/calls"
print 1 > "$ROOT/process"
wait_call resumeBackups
: > "$ROOT/calls"
print 'unrelated diagnostic entry' >> "$EXPLICIT_LOG"
print 0 > "$ROOT/process"
sleep 3
if grep -Fq pauseBackups "$ROOT/calls" || [[ -f "$ROOT/state/guard-paused" ]]; then
  print -u2 'Explicit source replayed a pre-exit active event'; exit 1
fi
console_event 03:30:20 Streaming >> "$EXPLICIT_LOG"
wait_call 'pauseBackups 10'
stop_guard
# Timestamp-free explicit diagnostics use the event's position: noise must
# not replay a start, but a repeated identical IPC start on a new line must.
rm -f "$ROOT/state/guard-paused"
: > "$ROOT/calls"
print IPC_STREAMING_STARTED_EVENT > "$EXPLICIT_LOG"
start_explicit_guard
wait_call 'pauseBackups 10'
: > "$ROOT/calls"
print 1 > "$ROOT/process"
wait_call resumeBackups
: > "$ROOT/calls"
print 'unrelated diagnostic entry' >> "$EXPLICIT_LOG"
print 0 > "$ROOT/process"
sleep 3
[[ ! -s "$ROOT/calls" ]] || { print -u2 'Bare explicit event replayed after exit'; exit 1; }
print IPC_STREAMING_STARTED_EVENT >> "$EXPLICIT_LOG"
wait_call 'pauseBackups 10'
stop_guard
print 'All source edge tests passed' 
