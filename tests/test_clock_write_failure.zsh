#!/bin/zsh
# Real rollback, failed metadata rename, successful lease save, and restart.
set -eu
unsetopt bg_nice
readonly REPO="${0:A:h:h}"
readonly ROOT="$(mktemp -d /tmp/arq-clock-write.XXXXXX)"
readonly LOGS="$ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
monitor_pid=""
trap '[[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
mkdir -p "$LOGS" "$ROOT/state"
cat > "$ROOT/mv" <<'EOF'
#!/bin/zsh
if [[ "$*" == *guard-clock && -f "$TEST_ROOT/fail-clock" ]]; then exit 42; fi
exec /bin/mv "$@"
EOF
cat > "$ROOT/arqc" <<'EOF'
#!/bin/zsh
print -r -- "$*" >> "$TEST_ROOT/calls"
EOF
chmod +x "$ROOT/mv" "$ROOT/arqc"
# Replace only the external rename command for the independent metadata file.
sed "s#&& mv -f \"\$temporary_clock\"#\&\& $ROOT/mv -f \"\$temporary_clock\"#" \
 "${TEST_GUARD_SOURCE:-$REPO/arq-gfn-guard.sh}" > "$ROOT/guard"
chmod +x "$ROOT/guard"
export TEST_ROOT="$ROOT"
event() { print -r -- "2026-09-09 05:$1:00.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"; }
start_guard() {
 env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_STATE_DIR="$ROOT/state" \
 ARQ_GFN_GUARD_LOG="$ROOT/guard.log" ARQ_GFN_FORCE_PROCESS=1 \
 ARQ_GFN_LOOP_SECONDS=1 ARQ_GFN_SAFETY_SECONDS=1 ARQ_GFN_NOTIFICATIONS=0 \
 ARQ_GFN_ERROR_NOTIFICATIONS=0 "$ROOT/guard" &
 monitor_pid=$!
}
stop_guard() { kill "$monitor_pid"; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; }
event 59 Done > "$LOGS/debug.log"
event 58 Done > "$LOGS/console.log"
print -r -- 'clock-v1 - - -' > "$ROOT/state/guard-clock"
: > "$ROOT/calls"
: > "$ROOT/fail-clock"
start_guard
sleep 2
event 05 Streaming >> "$LOGS/console.log"
for attempt in {1..80}; do
 [[ -f "$ROOT/state/guard-paused" ]] && break
 sleep 0.1
done
[[ -f "$ROOT/state/guard-paused" ]] || { print -u2 'Rollback did not save owned lease'; exit 1; }
grep -Fq 'clock-v1 - - -' "$ROOT/state/guard-clock" \
 || { print -u2 'Expected old clock metadata after injected rename failure'; exit 1; }
stop_guard
rm "$ROOT/fail-clock"
: > "$ROOT/calls"
start_guard
sleep 3
[[ -f "$ROOT/state/guard-paused" && ! -s "$ROOT/calls" ]] \
 || { print -u2 'Stale clock file overrode successfully saved lease after restart'; exit 1; }
event 06 Done >> "$LOGS/console.log"
for attempt in {1..80}; do
 [[ ! -f "$ROOT/state/guard-paused" ]] && break
 sleep 0.1
done
[[ ! -f "$ROOT/state/guard-paused" ]] && grep -Fq resumeBackups "$ROOT/calls" \
 || { print -u2 'Authoritative end did not resume after recovery'; exit 1; }
stop_guard
print 'All clock write failure tests passed'
