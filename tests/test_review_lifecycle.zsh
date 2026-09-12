#!/bin/zsh
set -eu
unsetopt bg_nice
readonly GUARD="${0:A:h:h}/arq-gfn-guard.sh"
readonly ROOT="$(mktemp -d /tmp/arq-review.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
event() { print -r -- "2026-09-12 $1 INFO gfn/StreamerManagerService  Advancing to state: $2" >> "$3"; }
check() { "$@" || { print -u2 -- "FAIL: $*"; exit 1; }; }
setup() {
  export HOME="$ROOT/$1/home" ARQ_GFN_STATE_DIR="$ROOT/$1/state" \
    ARQ_GFN_GUARD_LOG="$ROOT/$1/guard.log" ARQ_GFN_ARQC="$ROOT/$1/arqc" \
    ARQ_TEST_ACTIONS="$ROOT/$1/actions" ARQ_GFN_FORCE_PROCESS=1 \
    ARQ_GFN_NOTIFICATIONS=0 ARQ_GFN_ERROR_NOTIFICATIONS=0
  mkdir -p "$HOME/Library/Application Support/NVIDIA/GeForceNOW" "$ARQ_GFN_STATE_DIR"
  print -rl -- '#!/bin/zsh' 'print -r -- "$*" >> "$ARQ_TEST_ACTIONS"' \
    '[[ ! -f "$ARQ_TEST_ACTIONS.fail" ]]' > "$ARQ_GFN_ARQC"
  chmod 700 "$ARQ_GFN_ARQC"
  : > "$ARQ_TEST_ACTIONS"
}
step() { select_log_source; reconcile_backup_state "$1" "$selected_signature_out"; }
restart() { ARQ_GFN_NOW="$1" ARQ_GFN_GUARD_ONCE=1 "$GUARD"; }
failures=0
for scenario in lease stopped rollback alerts action-alert replacement explicit resume unrelated-backup late-backup stopped-inactive candidate-error; do
  (
    setup "$scenario"
    if [[ "$scenario" == candidate-error ]]; then
      # Replace only the external tail reader to inject a real scan error.
      export ARQ_TEST_SCAN_FAIL="$ROOT/tail.fail"
      touch "$ARQ_TEST_SCAN_FAIL"
      print -rl -- '#!/bin/zsh' '[[ "${@[-1]}" == *console.log && -f "$ARQ_TEST_SCAN_FAIL" ]] && exit 42' \
        'exec /usr/bin/tail "$@"' > "$ROOT/tail"
      chmod +x "$ROOT/tail"
      source <(sed "s#/usr/bin/tail#$ROOT/tail#g" "$GUARD" | awk '/^restore_source_checkpoint \|\| true$/ {exit} {print}')
    else
      source <(awk '/^restore_source_checkpoint \|\| true$/ {exit} {print}' "$GUARD")
    fi
    case "$scenario" in
      late-backup)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1000
        mv "$GFN_DEBUG_LOG" "$GFN_DEBUG_LOG.bak"
        print noise > "$GFN_DEBUG_LOG"; step 1010
        print more-noise >> "$GFN_DEBUG_LOG"; step 1015
        event 11:01:00.000 Done "$GFN_DEBUG_LOG.bak"; step 1020
        check test ! -f "$STATE_FILE"
        event 11:02:00.000 Streaming "$GFN_DEBUG_LOG"; step 1030
        event 11:03:00.000 Done "$GFN_DEBUG_LOG.bak"; step 1040
        check test -f "$STATE_FILE"
        ;;
      stopped-inactive)
        event 12:00:00.000 Done "$GFN_CONSOLE_LOG"
        ARQ_GFN_FORCE_PROCESS=0; step 1000
        ARQ_GFN_FORCE_PROCESS=1
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1010
        check test -f "$STATE_FILE"
        restart 1020
        check test -f "$STATE_FILE"
        ;;
      candidate-error)
        event 11:00:00.000 Done "$GFN_DEBUG_LOG"
        event 12:00:00.000 Streaming "$GFN_CONSOLE_LOG"
        step 1000
        check test -n "$detection_alert_kind"
        event 13:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1030
        check test -f "$STATE_FILE"
        check test "$detection_alert_started" = 1000
        rm "$ARQ_TEST_SCAN_FAIL"; step 1060
        check test -z "$detection_alert_kind"
        ;;
      lease)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1000
        mv "$GFN_DEBUG_LOG" "$GFN_DEBUG_LOG.previous"
        print noise > "$GFN_DEBUG_LOG"; step 1100
        check test "$(head -1 "$STATE_FILE")" = 1000
        step 1240
        check test "$(grep -c pauseBackups "$ARQ_TEST_ACTIONS")" = 2
        ;;
      stopped)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"
        event 10:00:00.000 Done "$GFN_CONSOLE_LOG"; step 1000
        ARQ_GFN_FORCE_PROCESS=0; step 1010
        ARQ_GFN_FORCE_PROCESS=1; step 1020
        restart 1300
        check test ! -f "$STATE_FILE"
        ;;
      rollback)
        event 12:00:00.000 Streaming "$GFN_DEBUG_LOG"
        event 12:00:00.000 Streaming "$GFN_CONSOLE_LOG"; step 1000
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1010
        event 11:01:00.000 Done "$GFN_DEBUG_LOG"; step 1020
        event 10:00:00.000 Streaming "$GFN_CONSOLE_LOG"; step 1030
        check test -f "$STATE_FILE"
        ;;
      alerts)
        raise_alert gfn-log-unavailable 1000 missing missing
        raise_alert gfn-log-process-unknown 1030 unknown unknown
        check test "$detection_alert_started" = 1000
        detection_alert_notified=1
        raise_alert gfn-log-state-unknown 1060 unknown unknown
        check test "$detection_alert_notified" = 1
        ;;
      action-alert)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"
        touch "$ARQ_TEST_ACTIONS.fail"; step 1100
        event 12:00:00.000 Done "$GFN_DEBUG_LOG"
        ARQ_GFN_FORCE_PROCESS=unknown; step 1110
        check test ! -f "$ALERT_ACTION_STATE_FILE"
        ;;
      replacement)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1000
        mv "$GFN_DEBUG_LOG" "$GFN_DEBUG_LOG.bak"
        event 10:00:00.000 Done "$GFN_DEBUG_LOG"; step 1010
        check test -f "$STATE_FILE"
        ;;
      explicit)
        export ARQ_GFN_LOG_FILE="$GFN_DEBUG_LOG"
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; restart 1000
        ARQ_GFN_FORCE_PROCESS=0; restart 1010
        ARQ_GFN_FORCE_PROCESS=1; restart 1300
        check test ! -f "$STATE_FILE"
        restart 1350
        check test ! -f "$STATE_FILE"
        print noise >> "$GFN_DEBUG_LOG"; restart 1360
        check test ! -f "$STATE_FILE"
        event 12:00:00.000 Streaming "$GFN_DEBUG_LOG"; restart 1400
        check test -f "$STATE_FILE"
        ;;
      resume)
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1000
        touch "$ARQ_TEST_ACTIONS.fail"
        ARQ_GFN_FORCE_PROCESS=0; step 1010
        rm "$ARQ_TEST_ACTIONS.fail"
        ARQ_GFN_FORCE_PROCESS=1; restart 1300
        check test ! -f "$STATE_FILE"
        ;;
      unrelated-backup)
        printf '%200s\n' common-header > "$GFN_DEBUG_LOG"
        event 11:00:00.000 Streaming "$GFN_DEBUG_LOG"; step 1000
        printf '%200s\n' common-header > "$GFN_DEBUG_LOG.bak"
        event 12:00:00.000 Done "$GFN_DEBUG_LOG.bak"
        print unrelated-padding >> "$GFN_DEBUG_LOG.bak"
        mv "$GFN_DEBUG_LOG" "$GFN_DEBUG_LOG.previous"
        print noise > "$GFN_DEBUG_LOG"; step 1010
        check test -f "$STATE_FILE"
        ;;
    esac
  ) && print "PASS $scenario" || failures=$(( failures + 1 ))
done
(( failures == 0 ))
