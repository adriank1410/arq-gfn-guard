#!/bin/zsh

emulate -LR zsh
setopt nounset
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

readonly ARQC="${ARQ_GFN_ARQC:-/Applications/Arq.app/Contents/Resources/arqc}"
# GFN 2.0.88 stopped forwarding session events to the reliability monitor.
# The launcher's state machine is logged here on both 2.0.87 and 2.0.88.
readonly GFN_LOG_FILE="${ARQ_GFN_LOG_FILE:-$HOME/Library/Application Support/NVIDIA/GeForceNOW/console.log}"
readonly STATE_DIR="${ARQ_GFN_STATE_DIR:-$HOME/Library/Application Support/ArqGFNGuard}"
readonly STATE_FILE="$STATE_DIR/guard-paused"
readonly GUARD_LOG="${ARQ_GFN_GUARD_LOG:-$HOME/Library/Logs/ArqGFNGuard/guard.log}"
readonly PAUSE_MINUTES=10
readonly RENEW_SECONDS=240
readonly LOOP_SECONDS="${ARQ_GFN_LOOP_SECONDS:-2}"
readonly SAFETY_SECONDS="${ARQ_GFN_SAFETY_SECONDS:-60}"
readonly LOG_SCAN_BYTES=1048576
readonly CHECKPOINT_BYTES=128
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

has_system=false
if zmodload zsh/system 2>/dev/null; then
  has_system=true
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

# Open before invoking Arq: a failed redirection must never skip the command.
# The descriptor also remains usable if cleanup unlinks the log after opening.
open_guard_log() {
  mkdir -p "${GUARD_LOG:h}" 2>/dev/null || return 1
  chmod 700 "${GUARD_LOG:h}" 2>/dev/null || true
  { exec {guard_log_fd}>> "$GUARD_LOG"; } 2>/dev/null || return 1
  chmod 600 "$GUARD_LOG" 2>/dev/null || true
}

log_message() {
  local guard_log_fd
  if open_guard_log; then
    print -r -- "$(timestamp) $1" >&$guard_log_fd
    exec {guard_log_fd}>&-
  else
    print -ru2 -- "$(timestamp) $1"
  fi
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

parse_stream_state() {
  /usr/bin/awk '
    / INFO +gfn\/StreamerManagerService +Advancing to state: (Loading|Streaming)[[:space:]]*$/ {
      stream_state = "active"
    }
    / INFO +gfn\/StreamerManagerService +Advancing to state: (PostSessionConnection|PostStreaming|Done)[[:space:]]*$/ {
      stream_state = "inactive"
    }
    # Legacy events require their own format, independently of the pathname.
    # Bare IPC event lines are useful for diagnostics and isolated fixtures.
    /^[[:space:]]*IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT[[:space:]]*$/ ||
    (/gfn_streamer_diagnostics[.]cpp[(][0-9]+[)]/ && /IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT|streaming started/) {
      stream_state = "active"
    }
    /^[[:space:]]*IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT[[:space:]]*$/ ||
    (/gfn_streamer_diagnostics[.]cpp[(][0-9]+[)]/ && /IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT|streaming terminated|GFN UI exited streaming mode/) {
      stream_state = "inactive"
    }
    END { print stream_state }
  ' "$@"
}

# Parsed state is process-local. The lease persists only source evidence so
# restart recovery can identify its rotated log, never assume an active state.
parsed_signature=""
parsed_identity=""
parsed_size=0
parsed_stream_state=""
parsed_prefix=""
parsed_suffix=""
current_source_event=0

# Compare small byte checkpoints before trusting append-only growth. Reading
# at the OLD size detects copytruncate/regrowth without scanning the prefix.
# zsh/system avoids spawning extra processes for these bounded reads.
log_checkpoint() {
  local source_size="$1"
  local checkpoint_file="${2:-$GFN_LOG_FILE}"
  local chunk_size=$(( source_size < CHECKPOINT_BYTES ? source_size : CHECKPOINT_BYTES ))
  local checkpoint_fd bytes_read
  checkpoint_prefix_out=""
  checkpoint_suffix_out=""
  [[ "$has_system" == true ]] || return 1
  (( chunk_size > 0 )) || return 0
  { exec {checkpoint_fd}< "$checkpoint_file"; } 2>/dev/null || return 1
  {
    sysread -i "$checkpoint_fd" -s "$chunk_size" -c bytes_read checkpoint_prefix_out || return 1
    (( bytes_read == chunk_size )) || return 1
    sysseek -u "$checkpoint_fd" $(( source_size - chunk_size )) || return 1
    sysread -i "$checkpoint_fd" -s "$chunk_size" -c bytes_read checkpoint_suffix_out || return 1
    (( bytes_read == chunk_size )) || return 1
  } always {
    exec {checkpoint_fd}<&-
  }
}

latest_stream_state() {
  setopt localoptions pipefail
  local source_signature="$1"
  detected_stream_state_out=""
  [[ -f "$GFN_LOG_FILE" && "$source_signature" != missing \
      && "$source_signature" != unreadable ]] || {
    parsed_signature=""
    return 0
  }
  if [[ "$source_signature" == "$parsed_signature" ]] \
      && log_checkpoint "$parsed_size" \
      && [[ "$checkpoint_prefix_out" == "$parsed_prefix" \
         && "$checkpoint_suffix_out" == "$parsed_suffix" ]]; then
    # Safety reconciliation also reaches this check, detecting a same-size
    # rewrite hidden by stat mtime resolution even if the file stays quiet.
    detected_stream_state_out="$parsed_stream_state"
    return 0
  fi

  local source_identity="${source_signature%:*}"
  source_identity="${source_identity%:*}"
  local source_size="${source_signature##*:}"
  local recover=0 replacement=0 detected_state
  if [[ -n "$parsed_identity" ]]; then
    if [[ "$source_identity" != "$parsed_identity" ]] || (( source_size <= parsed_size )); then
      replacement=1
    elif ! log_checkpoint "$parsed_size" \
        || [[ "$checkpoint_prefix_out" != "$parsed_prefix" \
           || "$checkpoint_suffix_out" != "$parsed_suffix" ]]; then
      replacement=1
    fi
  fi
  if [[ -z "$parsed_signature" ]] \
      || (( replacement || source_size - parsed_size >= LOG_SCAN_BYTES )); then
    recover=1
  fi

  current_source_event=0
  detected_state="$(/usr/bin/tail -c "$LOG_SCAN_BYTES" "$GFN_LOG_FILE" 2>/dev/null | parse_stream_state)" || return 0
  if [[ -z "$detected_state" ]] && (( recover )); then
    # Full scans are for startup, rotation/truncation, and unseen bursts that
    # could have pushed an end outside the tail. Ordinary appends retain the
    # last parsed state instead of repeatedly scanning the entire file.
    detected_state="$(parse_stream_state "$GFN_LOG_FILE" 2>/dev/null)" || return 0
  fi
  if [[ -n "$detected_state" ]]; then
    current_source_event=1
  elif (( ! recover )); then
    detected_state="$parsed_stream_state"
  fi
  if [[ -z "$detected_state" ]] && (( replacement && parsed_size > 0 )); then
    # A last end event may have moved to .bak before we saw it. Only trust
    # the prior source inode, or a copy matching its recorded checkpoints;
    # an unrelated backup from an older session must never resume Arq.
    local backup_file="$GFN_LOG_FILE.bak"
    log_signature "$backup_file"
    if [[ "$log_signature_out" != missing && "$log_signature_out" != unreadable ]]; then
      local backup_identity="${log_signature_out%:*}"
      backup_identity="${backup_identity%:*}"
      local backup_size="${log_signature_out##*:}"
      if [[ "$backup_identity" == "$parsed_identity" ]] \
          || { (( backup_size >= parsed_size )) \
               && log_checkpoint "$parsed_size" "$backup_file" \
               && [[ "$checkpoint_prefix_out" == "$parsed_prefix" \
                  && "$checkpoint_suffix_out" == "$parsed_suffix" ]]; }; then
        detected_state="$(parse_stream_state "$backup_file" 2>/dev/null)" || detected_state=""
      fi
    fi
  fi
  parsed_signature=""
  if log_checkpoint "$source_size"; then
    parsed_prefix="$checkpoint_prefix_out"
    parsed_suffix="$checkpoint_suffix_out"
    parsed_signature="$source_signature"
  fi
  parsed_identity="$source_identity"
  parsed_size="$source_size"
  parsed_stream_state="$detected_state"
  detected_stream_state_out="$detected_state"
}

log_signature() {
  local signature_file="${1:-$GFN_LOG_FILE}"
  [[ -f "$signature_file" ]] || {
    log_signature_out="missing"
    return 0
  }

  if [[ "$has_stat" == true ]]; then
    local -A file_stat
    zstat -H file_stat -- "$signature_file" 2>/dev/null || {
      log_signature_out="unreadable"
      return 0
    }
    # Rotation may preserve both size and mtime; include the file identity.
    log_signature_out="${file_stat[device]}:${file_stat[inode]}:${file_stat[mtime]}:${file_stat[size]}"
  else
    log_signature_out="$(/usr/bin/stat -f '%d:%i:%m:%z' "$signature_file" 2>/dev/null)" \
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

# The first line remains the legacy renewal timestamp. An optional versioned
# header and two raw byte checkpoints follow; no stored text is evaluated.
restore_source_checkpoint() {
  [[ "$has_system" == true && -f "$STATE_FILE" ]] || return 1
  local proof_fd saved_epoch proof_version proof_identity proof_size extra
  local prefix_data suffix_data chunk_size bytes_read
  { exec {proof_fd}< "$STATE_FILE"; } 2>/dev/null || return 1
  {
    IFS= read -r -u "$proof_fd" saved_epoch || return 1
    IFS=' ' read -r -u "$proof_fd" proof_version proof_identity proof_size extra || return 1
    [[ "$saved_epoch" =~ ^[0-9]+$ && ${#saved_epoch} -le 18 \
       && "$proof_version" == source-v1 && -z "$extra" \
       && "$proof_identity" =~ ^[0-9]{1,18}:[0-9]{1,18}$ \
       && "$proof_size" =~ ^[0-9]+$ && ${#proof_size} -le 18 ]] || return 1
    (( proof_size > 0 )) || return 1
    chunk_size=$(( proof_size < CHECKPOINT_BYTES ? proof_size : CHECKPOINT_BYTES ))
    sysread -i "$proof_fd" -s "$chunk_size" -c bytes_read prefix_data || return 1
    (( bytes_read == chunk_size )) || return 1
    sysread -i "$proof_fd" -s "$chunk_size" -c bytes_read suffix_data || return 1
    (( bytes_read == chunk_size )) || return 1
    parsed_identity="$proof_identity"
    parsed_size="$proof_size"
    parsed_prefix="$prefix_data"
    parsed_suffix="$suffix_data"
  } always {
    exec {proof_fd}<&-
  }
}

write_state_timestamp() {
  local epoch_value="$1"
  local temporary_state
  mkdir -p "$STATE_DIR" 2>/dev/null || {
    log_message "ERROR: could not recreate state directory"
    return 1
  }
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  temporary_state="$(/usr/bin/mktemp "$STATE_DIR/.guard-paused.XXXXXX")" || {
    log_message "ERROR: could not create temporary state file"
    return 1
  }
  if ! {
    print -r -- "$epoch_value" && {
      if (( current_source_event && parsed_size > 0 )) && [[ -n "$parsed_signature" ]]; then
        print -r -- "source-v1 $parsed_identity $parsed_size" \
          && print -rn -- "$parsed_prefix$parsed_suffix"
      elif [[ -f "$STATE_FILE" ]]; then
        # Keep the last proven source while rotation hides current events.
        /usr/bin/tail -n +2 "$STATE_FILE"
      fi
    }
  } > "$temporary_state"; then
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

  local guard_log_fd arqc_exit
  if open_guard_log; then
    "$ARQC" "$@" >&$guard_log_fd 2>&1
    arqc_exit=$?
    exec {guard_log_fd}>&-
  else
    print -ru2 -- "WARN: guard log unavailable; invoking arqc with stderr output"
    "$ARQC" "$@" >&2
    arqc_exit=$?
  fi
  if (( arqc_exit != 0 )); then
    log_message "ERROR: arqc ${1:-unknown} failed with exit code $arqc_exit"
    return "$arqc_exit"
  fi
}

reconcile_backup_state() {
  local now_epoch="$1"
  local source_signature="$2"
  local detected_stream_state=""
  local current_stream_state="inactive"
  local process_state="unknown"
  local previous_renewal=0
  local first_pause=0

  gfn_process_state
  process_state="$gfn_process_state_out"
  if [[ "$process_state" == "running" ]]; then
    latest_stream_state "$source_signature"
    detected_stream_state="$detected_stream_state_out"
    if [[ "$detected_stream_state" == "active" ]]; then
      current_stream_state="active"
    elif [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      # If rotation/removal temporarily hides the session markers, the
      # private state file keeps the lease alive until evidence returns.
      current_stream_state="active"
    fi
  elif [[ "$process_state" == "unknown" ]]; then
    log_message "WARN: could not determine whether the GFN process is running"
    latest_stream_state "$source_signature"
    detected_stream_state="$detected_stream_state_out"
    if [[ "$detected_stream_state" == "active" ]] \
        || [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      current_stream_state="active"
    fi
  else
    # Do not carry old stream evidence into a new launcher process after
    # a crash/quit. Its startup rotation may retain an old active .bak.
    parsed_signature=""
    parsed_identity=""
    parsed_size=0
    parsed_stream_state=""
    parsed_prefix=""
    parsed_suffix=""
    current_source_event=0
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

restore_source_checkpoint || true

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
    reconcile_backup_state "$now_epoch" "$current_signature"
    last_signature="$current_signature"
    iterations_since_reconcile=0
    rotate_log_if_needed
  fi

  if [[ "${ARQ_GFN_GUARD_ONCE:-0}" == "1" ]]; then
    break
  fi
  guard_sleep
done
