#!/bin/zsh
# Append a lifecycle event after tail reads its snapshot but before it returns.
# Only external tail/arqc boundaries are substituted; selection/cache are real.
set -eu
unsetopt bg_nice
readonly REPO="${0:A:h:h}"
readonly ROOT="$(mktemp -d /tmp/arq-snapshot.XXXXXX)"
readonly LOGS="$ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
monitor_pid=""
trap '[[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
mkdir -p "$LOGS"
cat > "$ROOT/tail" <<'TAIL'
#!/bin/zsh
/usr/bin/tail "$@"
if [[ "${@[-1]}" == "$TEST_SOURCE" && -f "$TEST_ARM" ]]; then
 /bin/rm "$TEST_ARM"
 /bin/cat "$TEST_EVENT" >> "$TEST_SOURCE"
fi
TAIL
cat > "$ROOT/arqc" <<'ARQC'
#!/bin/zsh
print -r -- "$*" >> "$TEST_CALLS"
ARQC
chmod +x "$ROOT/tail" "$ROOT/arqc"
sed "s#/usr/bin/tail#$ROOT/tail#g" "$REPO/arq-gfn-guard.sh" > "$ROOT/guard"
chmod +x "$ROOT/guard"
export TEST_SOURCE="$LOGS/debug.log" TEST_ARM="$ROOT/armed" TEST_EVENT="$ROOT/event" TEST_CALLS="$ROOT/calls"
event() { print "[1:1:2026-09-09/ 23:00:$1.000:INFO:gfn_background_agent_ipc.cpp(29)] Sending 'IPC_STREAMING_${2}_EVENT' to BackgroundAgent"; }
wait_action() {
 local attempt
 for attempt in {1..80}; do
  if [[ -f "$TEST_CALLS" ]] && grep -Fq "$1" "$TEST_CALLS"; then
   if [[ "$1" == 'pauseBackups 10' && -f "$ROOT/state/guard-paused" ]] \
     || [[ "$1" == resumeBackups && ! -f "$ROOT/state/guard-paused" ]]; then return; fi
  fi
  sleep 0.1
 done
 print -u2 "Snapshot race lost $1"; exit 1
}
event 10 TERMINATED > "$TEST_SOURCE"
event 20 STARTED > "$TEST_EVENT"
: > "$TEST_ARM"
env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_STATE_DIR="$ROOT/state" \
 ARQ_GFN_GUARD_LOG="$ROOT/guard.log" ARQ_GFN_LOOP_SECONDS=1 ARQ_GFN_SAFETY_SECONDS=1 \
 ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0 "$ROOT/guard" &
monitor_pid=$!
wait_action 'pauseBackups 10'
# A second race on termination must also reconcile even if no more writes occur.
event 30 TERMINATED > "$TEST_EVENT"
: > "$TEST_ARM"
print 'unrelated diagnostic entry' >> "$TEST_SOURCE"
wait_action resumeBackups
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""
print 'All snapshot race tests passed'
