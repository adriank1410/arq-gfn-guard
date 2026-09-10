#!/bin/zsh
# Count real parser file reads while the production loop handles native files.
set -eu
unsetopt bg_nice
readonly REPO="${0:A:h:h}"
readonly ROOT="$(mktemp -d /tmp/arq-empty-history.XXXXXX)"
readonly LOGS="$ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
monitor_pid=""
trap '[[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
mkdir -p "$LOGS"
cat > "$ROOT/awk" <<'EOF'
#!/bin/zsh
if [[ "${@[-1]}" == "$TEST_SOURCE" ]]; then
 print scan >> "$TEST_SCANS"
 if [[ -f "$TEST_FAIL_SCAN" ]]; then /bin/rm "$TEST_FAIL_SCAN"; exit 42; fi
fi
exec /usr/bin/awk "$@"
EOF
cat > "$ROOT/arqc" <<'EOF'
#!/bin/zsh
print -r -- "$*" >> "$TEST_CALLS"
EOF
chmod +x "$ROOT/awk" "$ROOT/arqc"
sed "s#/usr/bin/awk#$ROOT/awk#g" "$REPO/arq-gfn-guard.sh" > "$ROOT/guard"
chmod +x "$ROOT/guard"
export TEST_SOURCE="$LOGS/console.log" TEST_SCANS="$ROOT/scans" TEST_FAIL_SCAN="$ROOT/fail-scan" TEST_CALLS="$ROOT/calls"
event() { print -r -- "2026-09-10 12:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"; }
large_diagnostics() { /usr/bin/awk 'BEGIN {for(i=0;i<16000;i++) print "diagnostic padding ................................................................"}'; }
start_guard() {
 env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_STATE_DIR="$ROOT/state" \
 ARQ_GFN_GUARD_LOG="$ROOT/guard.log" ARQ_GFN_FORCE_PROCESS=1 \
 ARQ_GFN_LOOP_SECONDS=1 ARQ_GFN_SAFETY_SECONDS=1 ARQ_GFN_NOTIFICATIONS=0 \
 ARQ_GFN_ERROR_NOTIFICATIONS=0 "$ROOT/guard" &
 monitor_pid=$!
}
stop_guard() { kill "$monitor_pid"; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; }
wait_owned() {
 for attempt in {1..100}; do
  [[ -f "$ROOT/state/guard-paused" ]] && return
  sleep 0.1
 done
 print -u2 'New lifecycle was not recovered'; exit 1
}
event 10 Done > "$LOGS/debug.log"
large_diagnostics > "$TEST_SOURCE"
start_guard
sleep 2
for iteration in 1 2 3; do
 print "another diagnostic $iteration" >> "$TEST_SOURCE"
 sleep 2
done
[[ "$(wc -l < "$TEST_SCANS" | tr -d ' ')" == 1 ]] \
 || { print -u2 'Marker-free history was fully rescanned after ordinary appends'; exit 1; }
# Replacement invalidates an empty history; its event is outside the tail.
{ event 20 Streaming; large_diagnostics; } > "$ROOT/replacement"
mv "$ROOT/replacement" "$TEST_SOURCE"
wait_owned
[[ "$(wc -l < "$TEST_SCANS" | tr -d ' ')" == 2 ]] \
 || { print -u2 'Replacement did not invalidate empty history'; exit 1; }
stop_guard
rm -f "$ROOT/state/guard-paused"
: > "$TEST_CALLS"
: > "$TEST_FAIL_SCAN"
# A failed full scan is not a valid empty-history result. Retry it even when
# the source signature remains unchanged and the next tail still has no event.
start_guard
wait_owned
stop_guard
print 'All empty history cache tests passed'
