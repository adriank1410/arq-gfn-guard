#!/bin/zsh

emulate -LR zsh
setopt nounset
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

readonly ARQC="${ARQ_GFN_ARQC:-/Applications/Arq.app/Contents/Resources/arqc}"
readonly GFN_LOG_FILE="${ARQ_GFN_LOG_FILE:-$HOME/Library/Application Support/NVIDIA/GeForceNOW/logs/gfn_reliability_monitor.log}"
readonly STATE_DIR="${ARQ_GFN_STATE_DIR:-$HOME/Library/Application Support/ArqGFNGuard}"
readonly STATE_FILE="$STATE_DIR/guard-paused"
readonly GUARD_LOG="${ARQ_GFN_GUARD_LOG:-$HOME/Library/Logs/ArqGFNGuard/guard.log}"
readonly PAUSE_MINUTES=10
readonly RENEW_SECONDS=240
readonly LOOP_SECONDS="${ARQ_GFN_LOOP_SECONDS:-2}"
readonly SAFETY_SECONDS="${ARQ_GFN_SAFETY_SECONDS:-60}"
readonly LOG_SCAN_BYTES=1048576
readonly NOTIFICATIONS_ENABLED="${ARQ_GFN_NOTIFICATIONS:-0}"
readonly NOTIFICATION_LANGUAGE="${ARQ_GFN_LANG:-}"

if [[ ! "$LOOP_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "$SAFETY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  print -u2 -- "ARQ GFN guard: loop and safety intervals must be positive integers"
  exit 2
fi
if [[ "$NOTIFICATIONS_ENABLED" != "0" && "$NOTIFICATIONS_ENABLED" != "1" ]]; then
  print -u2 -- "ARQ GFN guard: ARQ_GFN_NOTIFICATIONS must be 0 or 1"
  exit 2
fi
if [[ -n "$NOTIFICATION_LANGUAGE" \
    && "$NOTIFICATION_LANGUAGE" != en* \
    && "$NOTIFICATION_LANGUAGE" != pl* ]]; then
  print -u2 -- "ARQ GFN guard: ARQ_GFN_LANG must be en, pl, or empty for auto-detection"
  exit 2
fi
readonly SAFETY_ITERATIONS=$(( (SAFETY_SECONDS + LOOP_SECONDS - 1) / LOOP_SECONDS ))

mkdir -p "$STATE_DIR" "${GUARD_LOG:h}"
chmod 700 "$STATE_DIR" "${GUARD_LOG:h}" 2>/dev/null || true
[[ -f "$GUARD_LOG" ]] && chmod 600 "$GUARD_LOG" 2>/dev/null || true

has_stat=false
if zmodload zsh/stat 2>/dev/null; then
  has_stat=true
fi

has_zselect=false
if zmodload zsh/zselect 2>/dev/null; then
  has_zselect=true
fi

current_epoch() {
  local epoch_value
  if [[ -n "${ARQ_GFN_NOW:-}" ]]; then
    epoch_value="$ARQ_GFN_NOW"
  else
    epoch_value="$(/bin/date +%s 2>/dev/null)" || epoch_value=""
  fi

  if [[ ! "$epoch_value" =~ ^[0-9]+$ ]] || (( ${#epoch_value} > 18 )); then
    return 1
  fi
  epoch_value_out="$epoch_value"
}

timestamp() {
  /bin/date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || print -r -- "UNKNOWN_TIME"
}

log_message() {
  print -r -- "$(timestamp) $1" >> "$GUARD_LOG"
  chmod 600 "$GUARD_LOG" 2>/dev/null || true
}

notify_user() {
  local english_message="$1"
  local polish_message="$2"
  local selected_language="$NOTIFICATION_LANGUAGE"
  local message_text

  if [[ "$NOTIFICATIONS_ENABLED" != "1" \
      || "${ARQ_GFN_GUARD_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -z "$selected_language" ]]; then
    selected_language="$(/usr/bin/defaults read -g AppleLocale 2>/dev/null)" \
      || selected_language="en"
  fi
  if [[ "$selected_language" == pl* ]]; then
    message_text="$polish_message"
  else
    message_text="$english_message"
  fi

  /usr/bin/osascript -e 'on run messageArgs' \
    -e 'display notification (item 1 of messageArgs) with title "Arq + GeForce NOW"' \
    -e 'end run' -- "$message_text" >/dev/null 2>&1 || true
}

gfn_process_state() {
  if [[ -n "${ARQ_GFN_FORCE_PROCESS:-}" ]]; then
    case "$ARQ_GFN_FORCE_PROCESS" in
      1) gfn_process_state_out="running" ;;
      0) gfn_process_state_out="stopped" ;;
      *) gfn_process_state_out="unknown" ;;
    esac
    return
  fi

  /usr/bin/pgrep -u "$UID" -x GeForceNOW >/dev/null 2>&1
  local probe_exit=$?
  case "$probe_exit" in
    0) gfn_process_state_out="running" ;;
    1) gfn_process_state_out="stopped" ;;
    *) gfn_process_state_out="unknown" ;;
  esac
}

latest_stream_state() {
  [[ -f "$GFN_LOG_FILE" ]] || return 0

  /usr/bin/tail -c "$LOG_SCAN_BYTES" "$GFN_LOG_FILE" 2>/dev/null | /usr/bin/awk '
    /IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT|streaming started/ {
      stream_state = "active"
    }
    /IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT|streaming terminated|GFN UI exited streaming mode/ {
      stream_state = "inactive"
    }
    END { print stream_state }
  '
}

log_signature() {
  [[ -f "$GFN_LOG_FILE" ]] || {
    log_signature_out="missing"
    return 0
  }

  if [[ "$has_stat" == true ]]; then
    local -A file_stat
    zstat -H file_stat -- "$GFN_LOG_FILE" 2>/dev/null || {
      log_signature_out="unreadable"
      return 0
    }
    log_signature_out="${file_stat[mtime]}:${file_stat[size]}"
  else
    log_signature_out="$(/usr/bin/stat -f '%m:%z' "$GFN_LOG_FILE" 2>/dev/null)" \
      || log_signature_out="unreadable"
  fi
}

read_state_timestamp() {
  local saved_epoch
  [[ -f "$STATE_FILE" ]] || return 1
  IFS= read -r saved_epoch < "$STATE_FILE" || saved_epoch=""
  if [[ ! "$saved_epoch" =~ ^[0-9]+$ ]] || (( ${#saved_epoch} > 18 )); then
    log_message "WARN: invalid state timestamp; forcing a safe reconciliation"
    return 1
  fi
  state_epoch_out="$saved_epoch"
}

write_state_timestamp() {
  local epoch_value="$1"
  local temporary_state
  temporary_state="$(/usr/bin/mktemp "$STATE_DIR/.guard-paused.XXXXXX")" || {
    log_message "ERROR: could not create temporary state file"
    return 1
  }
  if ! print -r -- "$epoch_value" > "$temporary_state"; then
    rm -f "$temporary_state"
    log_message "ERROR: could not write temporary state file"
    return 1
  fi
  chmod 600 "$temporary_state" 2>/dev/null || true
  if ! mv -f "$temporary_state" "$STATE_FILE"; then
    rm -f "$temporary_state"
    log_message "ERROR: could not atomically replace state file"
    return 1
  fi
}

run_arqc() {
  if [[ "${ARQ_GFN_GUARD_DRY_RUN:-0}" == "1" ]]; then
    log_message "DRY-RUN arqc $*"
    return 0
  fi

  if [[ ! -x "$ARQC" ]]; then
    log_message "ERROR: arqc not found or not executable at $ARQC"
    return 1
  fi

  "$ARQC" "$@" >> "$GUARD_LOG" 2>&1
  local arqc_exit=$?
  if (( arqc_exit != 0 )); then
    log_message "ERROR: arqc ${1:-unknown} failed with exit code $arqc_exit"
    return "$arqc_exit"
  fi
}

reconcile_backup_state() {
  local now_epoch="$1"
  local detected_stream_state=""
  local current_stream_state="inactive"
  local process_state="unknown"
  local previous_renewal=0
  local first_pause=0

  gfn_process_state
  process_state="$gfn_process_state_out"
  if [[ "$process_state" == "running" ]]; then
    detected_stream_state="$(latest_stream_state)"
    if [[ "$detected_stream_state" == "active" ]]; then
      current_stream_state="active"
    elif [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      # If an exceptionally long session pushes its start marker outside the
      # bounded log window, the private state file keeps the lease alive.
      current_stream_state="active"
    fi
  elif [[ "$process_state" == "unknown" ]]; then
    log_message "WARN: could not determine whether the GFN process is running"
    detected_stream_state="$(latest_stream_state)"
    if [[ "$detected_stream_state" == "active" ]] \
        || [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      current_stream_state="active"
    fi
  fi

  if [[ "$current_stream_state" == "active" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
      if read_state_timestamp; then
        previous_renewal="$state_epoch_out"
        if (( previous_renewal > now_epoch )); then
          log_message "WARN: state timestamp is in the future; forcing lease renewal"
          previous_renewal=0
        fi
      else
        previous_renewal=0
      fi
    else
      first_pause=1
    fi

    if (( now_epoch - previous_renewal >= RENEW_SECONDS )); then
      if run_arqc pauseBackups "$PAUSE_MINUTES"; then
        if write_state_timestamp "$now_epoch"; then
          log_message "GFN stream active; Arq pause renewed for $PAUSE_MINUTES minutes"
          if (( first_pause )); then
            notify_user \
              "Backup paused for the active GeForce NOW session." \
              "Backup wstrzymany na czas aktywnej sesji GeForce NOW."
          fi
        else
          log_message "WARN: Arq is paused but guard state was not saved; pause will expire automatically"
        fi
      fi
    fi
  elif [[ -f "$STATE_FILE" ]]; then
    # Arq exposes one global pause and no supported CLI readback for the pause
    # that existed before this guard acted. The state file proves that this
    # guard successfully issued a pause, but overlapping independent manual
    # pauses are intentionally documented as unsupported.
    if run_arqc resumeBackups; then
      rm -f "$STATE_FILE"
      log_message "GFN stream inactive; Arq resumed"
      notify_user \
        "GeForce NOW session ended; backup resumed." \
        "Sesja GeForce NOW zakończona; backup wznowiony."
    fi
  fi
}

rotate_log_if_needed() {
  [[ -f "$GUARD_LOG" ]] || return 0

  local log_size
  if [[ "$has_stat" == true ]]; then
    local -A log_stat
    zstat -H log_stat -- "$GUARD_LOG" 2>/dev/null || return 0
    log_size="${log_stat[size]}"
  else
    log_size="$(/usr/bin/stat -f '%z' "$GUARD_LOG" 2>/dev/null)" || return 0
  fi
  (( log_size > 262144 )) || return 0

  local temporary_log
  temporary_log="$(/usr/bin/mktemp "${GUARD_LOG:h}/.guard.log.XXXXXX")" || return 0
  if /usr/bin/tail -c 131072 "$GUARD_LOG" > "$temporary_log"; then
    chmod 600 "$temporary_log" 2>/dev/null || true
    mv -f "$temporary_log" "$GUARD_LOG" || rm -f "$temporary_log"
  else
    rm -f "$temporary_log"
  fi
}

guard_sleep() {
  if [[ "$has_zselect" == true ]]; then
    zselect -t $(( LOOP_SECONDS * 100 )) >/dev/null 2>&1 || true
  else
    /bin/sleep "$LOOP_SECONDS"
  fi
}

last_signature=""
iterations_since_reconcile=$SAFETY_ITERATIONS

while true; do
  log_signature
  current_signature="$log_signature_out"
  should_reconcile=0

  if [[ "$current_signature" != "$last_signature" ]]; then
    should_reconcile=1
  else
    iterations_since_reconcile=$(( iterations_since_reconcile + 1 ))
    if (( iterations_since_reconcile >= SAFETY_ITERATIONS )); then
      should_reconcile=1
    fi
  fi

  if (( should_reconcile )); then
    current_epoch || {
      log_message "ERROR: invalid current timestamp"
      exit 2
    }
    now_epoch="$epoch_value_out"
    reconcile_backup_state "$now_epoch"
    last_signature="$current_signature"
    iterations_since_reconcile=0
    rotate_log_if_needed
  fi

  if [[ "${ARQ_GFN_GUARD_ONCE:-0}" == "1" ]]; then
    break
  fi
  guard_sleep
done
