#!/bin/zsh
# Actual byte windows and parser; only the external Arq command is replaced.
set -eu
readonly REPO="${0:A:h:h}"
readonly ROOT="$(mktemp -d /tmp/arq-tail-boundaries.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
readonly LOGS="$ROOT/home/Library/Application Support/NVIDIA/GeForceNOW"
mkdir -p "$LOGS"
cat > "$ROOT/arqc" <<'EOF'
#!/bin/zsh
print -r -- "$*" >> "$TEST_CALLS"
EOF
chmod +x "$ROOT/arqc"
export TEST_CALLS="$ROOT/calls"
debug_event() { print -r -- "[1:1:2026-09-09/ 12:00:$1.000:INFO:gfn_background_agent_ipc.cpp(29)] Sending 'IPC_STREAMING_${2}_EVENT' to BackgroundAgent"; }
console_event() { print -r -- "2026-09-09 12:00:$1.000 INFO  gfn/StreamerManagerService  Advancing to state: $2"; }
run_once() {
 env HOME="$ROOT/home" ARQ_GFN_ARQC="$ROOT/arqc" ARQ_GFN_STATE_DIR="$ROOT/state" \
 ARQ_GFN_GUARD_LOG="$ROOT/guard.log" ARQ_GFN_FORCE_PROCESS=1 \
 ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0 ARQ_GFN_GUARD_ONCE=1 "$REPO/arq-gfn-guard.sh"
}
for source_name in debug console; do
 for transition in start end; do
  for boundary in partial complete; do
  rm -rf "$ROOT/state"
  : > "$ROOT/calls"
  if [[ "$transition" == end ]]; then
   debug_event 10 STARTED > "$LOGS/debug.log"
   console_event 10 Streaming > "$LOGS/console.log"
   run_once
   [[ -f "$ROOT/state/guard-paused" ]]
  fi
  if [[ "$source_name" == debug ]]; then
   cut_bytes=35
   if [[ "$transition" == start ]]; then
    lifecycle="$(debug_event 20 STARTED)"
    console_event 10 Done > "$LOGS/console.log"
   else
    lifecycle="$(debug_event 20 TERMINATED)"
   fi
  else
   cut_bytes=24
   if [[ "$transition" == start ]]; then
    lifecycle="$(console_event 20 Streaming)"
    debug_event 10 TERMINATED > "$LOGS/debug.log"
   else
    lifecycle="$(console_event 20 Done)"
   fi
  fi
  [[ "$boundary" == partial ]] || cut_bytes=0
  {
   print -r -- 'initial diagnostic entry'
   print -r -- "$lifecycle"
   /usr/bin/awk -v count="$((1048576 - ${#lifecycle} - 1 + cut_bytes))" 'BEGIN {for(i=0;i<count;i++) printf "x"}'
  } > "$LOGS/$source_name.log"
  run_once
  if [[ "$transition" == start ]]; then
   [[ -f "$ROOT/state/guard-paused" ]] || { print -u2 "Partial $source_name start lost to stale end"; exit 1; }
  else
   [[ ! -f "$ROOT/state/guard-paused" ]] || { print -u2 "Partial $source_name end lost to stale start"; exit 1; }
  fi
  done
 done
done
print 'All tail boundary tests passed'
