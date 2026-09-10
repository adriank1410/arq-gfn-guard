#!/bin/zsh

emulate -LR zsh
setopt nounset
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

readonly ARQC="${ARQ_GFN_ARQC:-/Applications/Arq.app/Contents/Resources/arqc}"
readonly STATE_DIR="${ARQ_GFN_STATE_DIR:-$HOME/Library/Application Support/ArqGFNGuard}"
readonly STATE_FILE="$STATE_DIR/guard-paused"
readonly CLOCK_STATE_FILE="$STATE_DIR/guard-clock"
readonly ALERT_STATE_FILE="$STATE_DIR/guard-alert"
readonly GUARD_LOG="${ARQ_GFN_GUARD_LOG:-$HOME/Library/Logs/ArqGFNGuard/guard.log}"
readonly PAUSE_MINUTES=10
readonly RENEW_SECONDS=240
readonly LOOP_SECONDS="${ARQ_GFN_LOOP_SECONDS:-2}"
readonly SAFETY_SECONDS="${ARQ_GFN_SAFETY_SECONDS:-60}"
readonly LOG_SCAN_BYTES=1048576
readonly CHECKPOINT_BYTES=128
readonly NOTIFICATIONS_ENABLED="${ARQ_GFN_NOTIFICATIONS:-0}"
readonly NOTIFICATION_LANGUAGE="${ARQ_GFN_LANG:-}"
readonly ERROR_NOTIFICATIONS_ENABLED="${ARQ_GFN_ERROR_NOTIFICATIONS:-1}"
readonly ALERT_DELAY_SECONDS="${ARQ_GFN_ALERT_DELAY_SECONDS:-60}"
readonly GFN_LOG_OVERRIDE="${ARQ_GFN_LOG_FILE:-}"
readonly GFN_LOG_DIR="$HOME/Library/Application Support/NVIDIA/GeForceNOW"
readonly GFN_DEBUG_LOG="$GFN_LOG_DIR/debug.log"
readonly GFN_CONSOLE_LOG="$GFN_LOG_DIR/console.log"
# GFN 2.0.88 stopped forwarding session events to the reliability monitor.
# The default selector uses only the two current lifecycle logs above. An
# explicit ARQ_GFN_LOG_FILE remains a single-source diagnostic override.
GFN_LOG_FILE="${GFN_LOG_OVERRIDE:-$GFN_DEBUG_LOG}"

if [[ ! "$LOOP_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "$SAFETY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  print -u2 -- "ARQ GFN guard: loop and safety intervals must be positive integers"
  exit 2
fi
if [[ "$NOTIFICATIONS_ENABLED" != "0" && "$NOTIFICATIONS_ENABLED" != "1" ]]; then
  print -u2 -- "ARQ GFN guard: ARQ_GFN_NOTIFICATIONS must be 0 or 1"
  exit 2
fi
if [[ "$ERROR_NOTIFICATIONS_ENABLED" != "0" && "$ERROR_NOTIFICATIONS_ENABLED" != "1" ]]; then
  print -u2 -- "ARQ GFN guard: ARQ_GFN_ERROR_NOTIFICATIONS must be 0 or 1"
  exit 2
fi
if [[ ! "$ALERT_DELAY_SECONDS" =~ ^[0-9]+$ ]] \
    || (( ${#ALERT_DELAY_SECONDS} > 18 )); then
  print -u2 -- "ARQ GFN guard: ARQ_GFN_ALERT_DELAY_SECONDS must be a non-negative integer"
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

readonly ALERT_DETECTION_STATE_FILE="$STATE_DIR/guard-alert-detection"
readonly ALERT_ACTION_STATE_FILE="$STATE_DIR/guard-alert-action"
detection_alert_kind=""
detection_alert_started=0
detection_alert_notified=0
action_alert_kind=""
action_alert_started=0
action_alert_notified=0

write_alert_slot() {
  local slot_name="$1"
  local temporary_alert alert_state_path
  local slot_kind slot_started slot_notified
  case "$slot_name" in
    detection)
      alert_state_path="$ALERT_DETECTION_STATE_FILE"
      slot_kind="$detection_alert_kind"
      slot_started="$detection_alert_started"
      slot_notified="$detection_alert_notified"
      ;;
    action)
      alert_state_path="$ALERT_ACTION_STATE_FILE"
      slot_kind="$action_alert_kind"
      slot_started="$action_alert_started"
      slot_notified="$action_alert_notified"
      ;;
    *) return 1 ;;
  esac
  temporary_alert="$(/usr/bin/mktemp "$STATE_DIR/.guard-alert.XXXXXX")" || return 1
  if ! print -r -- "$slot_kind $slot_started $slot_notified" > "$temporary_alert"; then
    rm -f "$temporary_alert"
    return 1
  fi
  chmod 600 "$temporary_alert" 2>/dev/null || true
  if ! mv -f "$temporary_alert" "$alert_state_path"; then
    rm -f "$temporary_alert"
    return 1
  fi
}

restore_alert_slot() {
  local slot_name="$1"
  local alert_state_path saved_kind saved_start saved_notified extra
  case "$slot_name" in
    detection) alert_state_path="$ALERT_DETECTION_STATE_FILE" ;;
    action) alert_state_path="$ALERT_ACTION_STATE_FILE" ;;
    *) return 1 ;;
  esac
  [[ -f "$alert_state_path" ]] || return 0
  IFS=' ' read -r saved_kind saved_start saved_notified extra < "$alert_state_path" || return 0
  [[ "$saved_kind" =~ ^[a-z0-9-]+$ \
     && "$saved_start" =~ ^[0-9]+$ && ${#saved_start} -le 18 \
     && ( "$saved_notified" == 0 || "$saved_notified" == 1 ) && -z "$extra" ]] || return 0
  if [[ "$slot_name" == detection ]]; then
    detection_alert_kind="$saved_kind"
    detection_alert_started="$saved_start"
    detection_alert_notified="$saved_notified"
  else
    action_alert_kind="$saved_kind"
    action_alert_started="$saved_start"
    action_alert_notified="$saved_notified"
  fi
}

restore_alert_episode() {
  restore_alert_slot detection
  restore_alert_slot action
  # Migrate the single-slot format written by older guards. Remove it only
  # after the replacement slot is safely written, so an interrupted upgrade
  # can retry from the legacy record.
  if [[ -f "$ALERT_STATE_FILE" ]] \
      && [[ -z "$detection_alert_kind" && -z "$action_alert_kind" ]]; then
    local saved_kind saved_start saved_notified extra
    IFS=' ' read -r saved_kind saved_start saved_notified extra < "$ALERT_STATE_FILE" || return 0
    [[ "$saved_kind" =~ ^[a-z0-9-]+$ \
       && "$saved_start" =~ ^[0-9]+$ && ${#saved_start} -le 18 \
       && ( "$saved_notified" == 0 || "$saved_notified" == 1 ) && -z "$extra" ]] || return 0
    case "$saved_kind" in
      gfn-log-*)
        detection_alert_kind="$saved_kind"
        detection_alert_started="$saved_start"
        detection_alert_notified="$saved_notified"
        if write_alert_slot detection; then
          rm -f "$ALERT_STATE_FILE" 2>/dev/null || true
        fi
        ;;
      *)
        action_alert_kind="$saved_kind"
        action_alert_started="$saved_start"
        action_alert_notified="$saved_notified"
        if write_alert_slot action; then
          rm -f "$ALERT_STATE_FILE" 2>/dev/null || true
        fi
        ;;
    esac
  fi
}

clear_alert_slot() {
  local slot_name="$1"
  case "$slot_name" in
    detection)
      detection_alert_kind=""
      detection_alert_started=0
      detection_alert_notified=0
      rm -f "$ALERT_DETECTION_STATE_FILE" 2>/dev/null || true
      ;;
    action)
      action_alert_kind=""
      action_alert_started=0
      action_alert_notified=0
      rm -f "$ALERT_ACTION_STATE_FILE" 2>/dev/null || true
      ;;
    *) return 1 ;;
  esac
}

clear_alert_episode() {
  clear_alert_slot detection
  clear_alert_slot action
  rm -f "$ALERT_STATE_FILE" 2>/dev/null || true
}

clear_detection_alert() {
  [[ "$detection_alert_kind" == gfn-log-* ]] || return 0
  clear_alert_slot detection
}

clear_action_alert() {
  case "$action_alert_kind" in
    pause-failure|resume-failure|state-save-failure) clear_alert_slot action ;;
  esac
}

notify_error() {
  local english_message="$1"
  local polish_message="$2"
  local selected_language="$NOTIFICATION_LANGUAGE"
  local message_text

  [[ "$ERROR_NOTIFICATIONS_ENABLED" == 1 \
     && "${ARQ_GFN_GUARD_DRY_RUN:-0}" != 1 ]] || return 2
  if [[ -z "$selected_language" ]]; then
    selected_language="$(/usr/bin/defaults read -g AppleLocale 2>/dev/null)" \
      || selected_language="en"
  fi
  if [[ "$selected_language" == pl* ]]; then
    message_text="$polish_message"
  else
    message_text="$english_message"
  fi
  if ! /usr/bin/osascript -e 'on run messageArgs' \
      -e 'display notification (item 1 of messageArgs) with title "Arq + GeForce NOW — guard"' \
      -e 'end run' -- "$message_text" >/dev/null 2>&1; then
    log_message "WARN: could not deliver error notification"
    return 1
  fi
  return 0
}

raise_alert() {
  local kind="$1"
  local now_epoch="$2"
  local english_message="$3"
  local polish_message="$4"
  local immediate="${5:-0}"
  local slot_name slot_kind slot_started slot_notified
  if [[ "$kind" == gfn-log-* ]]; then
    slot_name=detection
    slot_kind="$detection_alert_kind"
    slot_started="$detection_alert_started"
    slot_notified="$detection_alert_notified"
  else
    slot_name=action
    slot_kind="$action_alert_kind"
    slot_started="$action_alert_started"
    slot_notified="$action_alert_notified"
  fi
  if [[ "$slot_kind" != "$kind" ]] || (( slot_started > now_epoch )); then
    slot_kind="$kind"
    slot_started="$now_epoch"
    slot_notified=0
    if [[ "$slot_name" == detection ]]; then
      detection_alert_kind="$slot_kind"
      detection_alert_started="$slot_started"
      detection_alert_notified="$slot_notified"
    else
      action_alert_kind="$slot_kind"
      action_alert_started="$slot_started"
      action_alert_notified="$slot_notified"
    fi
    log_message "WARN: $english_message"
    write_alert_slot "$slot_name" || log_message "WARN: could not persist alert episode"
  fi
  if (( ! immediate && now_epoch - slot_started < ALERT_DELAY_SECONDS )); then
    return 0
  fi
  (( slot_notified )) && return 0
  if notify_error "$english_message" "$polish_message"; then
    slot_notified=1
    if [[ "$slot_name" == detection ]]; then
      detection_alert_notified="$slot_notified"
    else
      action_alert_notified="$slot_notified"
    fi
    write_alert_slot "$slot_name" || log_message "WARN: could not persist alert notification state"
  fi
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

parse_stream_evidence() {
  local watermark=0 skip_first_line=0
  while [[ "${1:-}" == --watermark || "${1:-}" == --skip-first-line ]]; do
    case "$1" in
      --watermark) watermark=1 ;;
      --skip-first-line) skip_first_line=1 ;;
    esac
    shift
  done
  /usr/bin/awk -v watermark="$watermark" -v skip_first_line="$skip_first_line" '
    NR == 1 && skip_first_line { next }
    function normalized_timestamp(value) {
      gsub(/[-\/:. ]/, "", value)
      return value
    }
    function line_timestamp(value) {
      # console.log: 2026-09-09 23:00:08.062
      if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9][.][0-9][0-9][0-9]/)) {
        value = substr($0, RSTART, RLENGTH)
        return normalized_timestamp(value)
      }
      # debug.log: 2026-09-09/ 23:00:08.062
      if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\/ [0-9][0-9]:[0-9][0-9]:[0-9][0-9][.][0-9][0-9][0-9]/)) {
        value = substr($0, RSTART, RLENGTH)
        return normalized_timestamp(value)
      }
      return ""
    }
    function record_state(next_state, event_time) {
      # Within one file, the last recognized line is authoritative. Timestamp
      # ordering is used only by the two-source selector, where it is compared
      # as text (the normalized value is 17 digits and must not pass through an
      # awk floating-point number).
      latest_state = next_state
      latest_time = event_time
      latest_line = NR
    }
    / INFO +gfn\/StreamerManagerService +Advancing to state: (Loading|Streaming)[[:space:]]*$/ {
      record_state("active", line_timestamp())
    }
    / INFO +gfn\/StreamerManagerService +Advancing to state: (PostSessionConnection|PostStreaming|Done)[[:space:]]*$/ {
      record_state("inactive", line_timestamp())
    }
    # Legacy events require their own format, independently of the pathname.
    # Bare IPC event lines are useful for diagnostics and isolated fixtures.
    /^[[:space:]]*IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT[[:space:]]*$/ ||
    (/gfn_streamer_diagnostics[.]cpp[(][0-9]+[)]/ && /IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT|streaming started/) {
      record_state("active", line_timestamp())
    }
    /gfn_background_agent_ipc[.]cpp[(][0-9]+[)].*Sending .*IPC_STREAMING_(PREPARE|STARTING|SESSION_SETUP|STARTED)_EVENT/ {
      record_state("active", line_timestamp())
    }
    /^[[:space:]]*IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT[[:space:]]*$/ ||
    (/gfn_streamer_diagnostics[.]cpp[(][0-9]+[)]/ && /IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT|streaming terminated|GFN UI exited streaming mode/) {
      record_state("inactive", line_timestamp())
    }
    /gfn_background_agent_ipc[.]cpp[(][0-9]+[)].*Sending .*IPC_STREAMING_(TERMINATED|MODE_EXIT)_EVENT/ {
      record_state("inactive", line_timestamp())
    }
    END {
      # Timestamp-free diagnostic fixtures need the event position to tell a
      # repeated new start from unrelated lines appended after an old start.
      if (watermark && latest_time == "") print latest_state "\t" latest_time "\t" latest_line
      else print latest_state "\t" latest_time
    }
  ' "$@"
}

# Include one preceding byte so a window beginning exactly on a full record
# retains it; discard the partial first line before recognizing any lifecycle.
bounded_stream_evidence() {
  local source_file="$1" source_size="$2"
  if (( source_size > LOG_SCAN_BYTES )); then
    /usr/bin/tail -c "$((LOG_SCAN_BYTES + 1))" "$source_file" 2>/dev/null \
      | parse_stream_evidence --skip-first-line
  else
    /usr/bin/tail -c "$LOG_SCAN_BYTES" "$source_file" 2>/dev/null | parse_stream_evidence
  fi
}

# The lease records a successful owned pause and its source evidence. After
# restart, that evidence can authenticate a rotated log; unrelated backups
# cannot establish whether the owned session ended.
parsed_signature=""
parsed_identity=""
parsed_size=0
parsed_stream_state=""
parsed_event_time=""
parsed_source_key=""
parsed_prefix=""
parsed_suffix=""
source_proof_ready=0

# Default-source evidence is cached independently for each candidate. This
# avoids rescanning both logs on every heartbeat while still allowing a newer
# event in the alternate file to win when either file changes.
debug_candidate_signature=""
debug_candidate_state=""
debug_candidate_time=""
debug_candidate_prefix=""
debug_candidate_suffix=""
console_candidate_signature=""
console_candidate_state=""
console_candidate_time=""
console_candidate_prefix=""
console_candidate_suffix=""
GFN_LOG_SOURCE_KEY=""
selected_source_has_evidence=0
selected_source_available=0
selected_source_untrusted=0
selected_source_suppressed=0
stopped_debug_evidence=""
stopped_console_evidence=""
stopped_explicit_signature=""
stopped_explicit_evidence=""
clock_source_key=""
clock_source_dirty=0
clock_debug_baseline=""
clock_console_baseline=""
clock_saved_snapshot=""
clock_pending_payload=""
clock_revision=0
owned_clock_revision=-1
clock_failure_logged=0
clock_failure_notified=0

clock_state_failure() {
  if (( ! clock_failure_logged )); then
    log_message "ERROR: could not read or save GFN clock recovery state"
    clock_failure_logged=1
  fi
  if (( ! clock_failure_notified )) && notify_error \
      "GFN clock recovery state could not be read or saved; detection after a restart may be unreliable." \
      "Nie można odczytać lub zapisać stanu zegara GFN; wykrywanie sesji po restarcie może być niepewne."; then
    clock_failure_notified=1
  fi
  return 1
}

restore_clock_state() {
  [[ -e "$CLOCK_STATE_FILE" || -L "$CLOCK_STATE_FILE" ]] || return 0
  local version saved_revision saved_key saved_debug saved_console extra
  local saved_payload apply_clock=1
  local baseline_pattern='^(active|inactive)?[|]([0-9]{17})?$'
  if [[ ! -f "$CLOCK_STATE_FILE" ]] \
      || ! IFS=' ' read -r version saved_key saved_debug saved_console extra < "$CLOCK_STATE_FILE"; then
    clock_state_failure
    return 1
  fi
  if [[ "$version" == clock-v1 ]]; then
    saved_revision=0
  elif [[ "$version" == clock-v2 ]]; then
    # The revision is read from the second field, so re-read the complete
    # record with the v2 layout before validating its payload.
    IFS=' ' read -r version saved_revision saved_key saved_debug saved_console extra < "$CLOCK_STATE_FILE" \
      || { clock_state_failure; return 1; }
    [[ "$saved_revision" =~ ^(0|[1-9][0-9]{0,17})$ ]] || {
      clock_state_failure
      return 1
    }
  else
    clock_state_failure
    return 1
  fi
  if [[ -n "$extra" ]] \
      || [[ "$saved_key" != - && "$saved_key" != debug && "$saved_key" != console ]] \
      || [[ "$saved_debug" != - && ! "$saved_debug" =~ "$baseline_pattern" ]] \
      || [[ "$saved_console" != - && ! "$saved_console" =~ "$baseline_pattern" ]]; then
    clock_state_failure
    return 1
  fi
  saved_payload="$saved_key $saved_debug $saved_console"
  if (( owned_clock_revision >= 0 && saved_revision < owned_clock_revision )); then
    apply_clock=0
  fi
  if (( apply_clock )); then
    clock_source_key="${saved_key/-/}"
    clock_debug_baseline="${saved_debug/-/}"
    clock_console_baseline="${saved_console/-/}"
    clock_revision="$saved_revision"
    clock_pending_payload="$saved_payload"
  fi
  if [[ "$version" == clock-v2 ]]; then
    clock_saved_snapshot="clock-v2 $saved_revision $saved_payload"
  else
    clock_saved_snapshot="clock-v1 $saved_payload"
  fi
}

write_clock_state() {
  local payload="${clock_source_key:--} ${clock_debug_baseline:--} ${clock_console_baseline:--}"
  local snapshot temporary_clock=""
  # A changed payload advances the monotonic ordering once, before the
  # filesystem write. A retry after a failed write keeps the same revision.
  [[ -n "$clock_pending_payload$clock_saved_snapshot$clock_source_key$clock_debug_baseline$clock_console_baseline" ]] || return 0
  if [[ "$payload" != "$clock_pending_payload" ]]; then
    [[ "$clock_revision" =~ ^(0|[1-9][0-9]{0,17})$ ]] \
      && (( clock_revision < 999999999999999999 )) || {
      clock_state_failure
      return 1
    }
    clock_revision=$(( clock_revision + 1 ))
    clock_pending_payload="$payload"
  fi
  snapshot="clock-v2 $clock_revision $payload"
  # No file is needed until a clock episode occurs. Unlike guard-paused, this
  # history survives a successful resume and protects launcher-only restarts.
  [[ "$snapshot" == "$clock_saved_snapshot" && -f "$CLOCK_STATE_FILE" ]] && return 0
  temporary_clock="$(/usr/bin/mktemp "$STATE_DIR/.guard-clock.XXXXXX")" || temporary_clock=""
  if [[ -n "$temporary_clock" && ! -d "$CLOCK_STATE_FILE" ]] \
      && print -r -- "$snapshot" > "$temporary_clock" \
      && chmod 600 "$temporary_clock" \
      && mv -f "$temporary_clock" "$CLOCK_STATE_FILE"; then
    clock_saved_snapshot="$snapshot"
    clock_failure_logged=0
    clock_failure_notified=0
    return 0
  fi
  [[ -z "$temporary_clock" ]] || rm -f "$temporary_clock"
  clock_state_failure
}

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

trusted_rotated_evidence() {
  local backup_file="$1.bak" backup_identity backup_size
  local proof_identity="${2-$parsed_identity}" proof_size="${3-$parsed_size}"
  local proof_prefix="${4-$parsed_prefix}" proof_suffix="${5-$parsed_suffix}"
  trusted_evidence_out=""
  [[ -n "$proof_identity" ]] || return 0
  log_signature "$backup_file"
  [[ "$log_signature_out" != missing && "$log_signature_out" != unreadable ]] || return 0
  backup_identity="${log_signature_out%:*}"
  backup_identity="${backup_identity%:*}"
  backup_size="${log_signature_out##*:}"
  # Only the prior inode or matching nonempty byte checkpoints prove that
  # this backup belongs to the source whose session we already observed.
  if [[ "$backup_identity" == "$proof_identity" ]] \
      || { (( proof_size > 0 && backup_size >= proof_size )) \
           && log_checkpoint "$proof_size" "$backup_file" \
           && [[ "$checkpoint_prefix_out" == "$proof_prefix" \
              && "$checkpoint_suffix_out" == "$proof_suffix" ]]; }; then
    trusted_evidence_out="$(parse_stream_evidence "$backup_file" 2>/dev/null)" || trusted_evidence_out=""
  fi
}

latest_stream_state() {
  setopt localoptions pipefail
  local source_signature="$1"
  local source_key="${GFN_LOG_SOURCE_KEY:-explicit}"
  detected_stream_state_out=""
  if (( selected_source_suppressed )); then
    return 0
  fi
  [[ -f "$GFN_LOG_FILE" && "$source_signature" != missing \
      && "$source_signature" != unreadable ]] || {
    parsed_signature=""
    return 0
  }
  if [[ "$source_signature" == "$parsed_signature" ]] \
      && [[ "$source_key" == "$parsed_source_key" ]] \
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
  local recover=0 replacement=0 detected_state detected_event_time evidence
  local previous_source_key="$parsed_source_key"
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

  source_proof_ready=0
  if [[ -z "$GFN_LOG_OVERRIDE" ]]; then
    # The selector already validated this source, including its own rotated
    # backup. Reuse that evidence rather than reparsing against another file's
    # selected checkpoint or reading the same log twice.
    if [[ "$source_key" == debug ]]; then
      evidence="$debug_candidate_state"$'\t'"$debug_candidate_time"
    else
      evidence="$console_candidate_state"$'\t'"$console_candidate_time"
    fi
  else
    evidence="$(bounded_stream_evidence "$GFN_LOG_FILE" "$source_size")" || return 0
  fi
  detected_state="${evidence%%$'\t'*}"
  detected_event_time="${evidence#*$'\t'}"
  if [[ -z "$detected_state" && -n "$GFN_LOG_OVERRIDE" ]] && (( recover )); then
    # Full scans are for startup, rotation/truncation, and unseen bursts that
    # could have pushed an end outside the tail. Ordinary appends retain the
    # last parsed state instead of repeatedly scanning the entire file.
    evidence="$(parse_stream_evidence "$GFN_LOG_FILE" 2>/dev/null)" || return 0
    detected_state="${evidence%%$'\t'*}"
    detected_event_time="${evidence#*$'\t'}"
  fi

  if [[ -n "$GFN_LOG_OVERRIDE" && "$detected_state" == active \
      && -n "$stopped_explicit_evidence" ]]; then
    local explicit_watermark
    explicit_watermark="$(parse_stream_evidence --watermark "$GFN_LOG_FILE" 2>/dev/null)" || return 0
    # Unrelated appends change stat without establishing a new session.
    [[ "$explicit_watermark" == "$stopped_explicit_evidence" ]] && return 0
    stopped_explicit_evidence=""
  fi

  # A source switch can expose an older inactive marker from the alternate
  # file after the owned active source was removed. Without a newer timestamp,
  # that marker is not evidence that this lease ended. Keep the lease alive;
  # the normal missing/unknown alert tells the user that the source is gone.
  selected_source_untrusted=0
  if [[ "$previous_source_key" != "$source_key" && "$clock_source_key" != "$source_key" ]] \
      && [[ "$previous_source_key" != legacy || "$source_identity" != "$parsed_identity" ]] \
      && [[ "$parsed_stream_state" == active ]] \
      && [[ "$detected_state" == inactive ]]; then
    if [[ -z "$detected_event_time" || -z "$parsed_event_time" || "$parsed_event_time" == - ]] \
        || [[ -n "$parsed_event_time" && "$detected_event_time" < "$parsed_event_time" ]]; then
      detected_state=""
      detected_event_time=""
      selected_source_untrusted=1
    fi
  fi
  if [[ -n "$detected_state" ]]; then
    source_proof_ready=1
  elif (( ! recover )); then
    detected_state="$parsed_stream_state"
    detected_event_time="$parsed_event_time"
  fi
  if [[ -z "$detected_state" ]] && (( replacement )); then
    # A last end event may have moved to .bak before we saw it. Only trust
    # the prior source inode, or a copy matching its recorded checkpoints;
    # an unrelated backup from an older session must never resume Arq.
    trusted_rotated_evidence "$GFN_LOG_FILE"
    if [[ -n "$trusted_evidence_out" ]]; then
        detected_state="${trusted_evidence_out%%$'\t'*}"
        detected_event_time="${trusted_evidence_out#*$'\t'}"
        # The trusted old source proves this new file continues the lease.
        # Persist its identity too, so successive rotations remain recoverable.
        [[ -z "$detected_state" ]] || source_proof_ready=1
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
  parsed_event_time="${detected_event_time:-${detected_state:+-}}"
  parsed_source_key="$source_key"
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

candidate_evidence() {
  local source_file="$1"
  local source_signature="$2"
  local previous_signature="$3"
  local previous_state="$4"
  local previous_time="$5"
  local previous_prefix="$6"
  local previous_suffix="$7"
  local source_identity previous_identity source_size previous_size
  local evidence candidate_state candidate_time same_source=0
  local previous_clock_baseline="$clock_console_baseline"
  [[ "$source_file" == "$GFN_DEBUG_LOG" ]] && previous_clock_baseline="$clock_debug_baseline"

  candidate_state_out=""
  candidate_time_out=""
  candidate_prefix_out=""
  candidate_suffix_out=""
  [[ "$source_signature" != missing && "$source_signature" != unreadable ]] || return 0
  source_identity="${source_signature%:*}"
  source_identity="${source_identity%:*}"
  source_size="${source_signature##*:}"
  previous_identity="${previous_signature%:*}"
  previous_identity="${previous_identity%:*}"
  previous_size="${previous_signature##*:}"
  if [[ "$source_identity" == "$previous_identity" ]] \
      && (( source_size >= previous_size )) \
      && log_checkpoint "$previous_size" "$source_file" \
      && [[ "$checkpoint_prefix_out" == "$previous_prefix" \
         && "$checkpoint_suffix_out" == "$previous_suffix" ]]; then
    same_source=1
  fi
  if (( same_source )) && (( source_size - previous_size < LOG_SCAN_BYTES )); then
    candidate_state_out="$previous_state"
    candidate_time_out="$previous_time"
    candidate_prefix_out="$previous_prefix"
    candidate_suffix_out="$previous_suffix"
    # Same signatures are normally enough, but a same-size rewrite can be
    # hidden by coarse mtime resolution. The bounded checkpoint comparison
    # above makes the non-selected source safe too.
    if [[ "$source_signature" == "$previous_signature" ]]; then
      return 0
    fi
  fi
  evidence="$(bounded_stream_evidence "$source_file" "$source_size")" || evidence=""
  candidate_state="${evidence%%$'\t'*}"
  candidate_time="${evidence#*$'\t'}"
  if [[ -z "$candidate_state" && -n "$previous_state" ]] \
      && (( source_size - previous_size < LOG_SCAN_BYTES )); then
    if (( same_source )); then
      candidate_state="$previous_state"
      candidate_time="$previous_time"
    fi
  fi
  if [[ -z "$candidate_state" && "$source_size" -gt "$LOG_SCAN_BYTES" ]]; then
    evidence="$(parse_stream_evidence "$source_file" 2>/dev/null)" || evidence=""
    candidate_state="${evidence%%$'\t'*}"
    candidate_time="${evidence#*$'\t'}"
  fi
  # Selection must consider a proven rotated event before choosing an older
  # marker in the alternate source. Unknown backups remain ineligible.
  if [[ -z "$candidate_state" && "$previous_identity" == *:* ]]; then
    trusted_rotated_evidence "$source_file" "$previous_identity" "$previous_size" \
      "$previous_prefix" "$previous_suffix"
    if [[ -n "$trusted_evidence_out" ]]; then
      candidate_state="${trusted_evidence_out%%$'\t'*}"
      candidate_time="${trusted_evidence_out#*$'\t'}"
    fi
  fi
  if [[ -z "$candidate_state" ]] \
      && { [[ "$source_file" == "$GFN_DEBUG_LOG" && "$parsed_source_key" == debug ]] \
        || [[ "$source_file" == "$GFN_CONSOLE_LOG" && "$parsed_source_key" == console ]]; }; then
    trusted_rotated_evidence "$source_file"
    if [[ -n "$trusted_evidence_out" ]]; then
      candidate_state="${trusted_evidence_out%%$'\t'*}"
      candidate_time="${trusted_evidence_out#*$'\t'}"
    fi
  fi
  # A backwards timestamp in a verified append establishes a new local-clock
  # epoch. Use that source until its session ends or the process exits; comparing
  # it with the other file's old wall clock would resurrect stale evidence.
  if (( same_source )) && [[ "$previous_state|$previous_time" != "$previous_clock_baseline" \
      && "$candidate_time" =~ ^[0-9]{17}$ \
      && "$previous_time" =~ ^[0-9]{17}$ && "x$candidate_time" < "x$previous_time" ]]; then
    local observed_clock_key=console
    [[ "$source_file" == "$GFN_DEBUG_LOG" ]] && observed_clock_key=debug
    [[ "$clock_source_key" == "$observed_clock_key" ]] || clock_source_dirty=1
    clock_source_key="$observed_clock_key"
  fi
  candidate_state_out="$candidate_state"
  candidate_time_out="$candidate_time"
  if log_checkpoint "$source_size" "$source_file"; then
    candidate_prefix_out="$checkpoint_prefix_out"
    candidate_suffix_out="$checkpoint_suffix_out"
  fi
}

select_log_source() {
  local debug_signature console_signature selected_signature selected_state
  local debug_state console_state
  local debug_available=0 console_available=0
  selected_source_suppressed=0

  if [[ -n "$GFN_LOG_OVERRIDE" ]]; then
    GFN_LOG_FILE="$GFN_LOG_OVERRIDE"
    GFN_LOG_SOURCE_KEY="explicit"
    selected_source_available=0
    log_signature "$GFN_LOG_FILE"
    selected_signature="$log_signature_out"
    selected_signature_out="$selected_signature"
    [[ "$selected_signature" == missing || "$selected_signature" == unreadable ]] \
      || selected_source_available=1
    selected_source_has_evidence=0
    selected_source_untrusted=0
    return 0
  fi

  log_signature "$GFN_DEBUG_LOG"
  debug_signature="$log_signature_out"
  log_signature "$GFN_CONSOLE_LOG"
  console_signature="$log_signature_out"

  candidate_evidence "$GFN_DEBUG_LOG" "$debug_signature" \
    "$debug_candidate_signature" "$debug_candidate_state" "$debug_candidate_time" \
    "$debug_candidate_prefix" "$debug_candidate_suffix"
  # Keep the last proof across a missing generation during rename rotation.
  if [[ "$debug_signature" != missing && "$debug_signature" != unreadable ]]; then
    debug_candidate_state="$candidate_state_out"
    debug_candidate_time="$candidate_time_out"
    debug_candidate_prefix="$candidate_prefix_out"
    debug_candidate_suffix="$candidate_suffix_out"
    debug_candidate_signature="$debug_signature"
  fi

  candidate_evidence "$GFN_CONSOLE_LOG" "$console_signature" \
    "$console_candidate_signature" "$console_candidate_state" "$console_candidate_time" \
    "$console_candidate_prefix" "$console_candidate_suffix"
  # Keep the last proof across a missing generation during rename rotation.
  if [[ "$console_signature" != missing && "$console_signature" != unreadable ]]; then
    console_candidate_state="$candidate_state_out"
    console_candidate_time="$candidate_time_out"
    console_candidate_prefix="$candidate_prefix_out"
    console_candidate_suffix="$candidate_suffix_out"
    console_candidate_signature="$console_signature"
  fi

  # Old active events belong to the process observed before it stopped.
  # Unrelated appends or a launcher-only reopen do not create a new session.
  debug_state="$debug_candidate_state"
  console_state="$console_candidate_state"
  # An end after clock rollback supersedes the other source's old epoch.
  # Keep its fingerprint excluded through noise appends until a new event.
  [[ "$debug_state|$debug_candidate_time" == "$clock_debug_baseline" ]] && debug_state=""
  [[ "$console_state|$console_candidate_time" == "$clock_console_baseline" ]] && console_state=""
  if [[ "$debug_state" == active && "$debug_state|$debug_candidate_time" == "$stopped_debug_evidence" ]]; then
    debug_state=""
  fi
  if [[ "$console_state" == active && "$console_state|$console_candidate_time" == "$stopped_console_evidence" ]]; then
    console_state=""
  fi

  [[ "$debug_signature" == missing || "$debug_signature" == unreadable ]] \
    || debug_available=1
  [[ "$console_signature" == missing || "$console_signature" == unreadable ]] \
    || console_available=1

  selected_signature="$debug_signature"
  selected_state="$debug_state"
  GFN_LOG_FILE="$GFN_DEBUG_LOG"
  GFN_LOG_SOURCE_KEY="debug"
  if (( !debug_available )) && (( console_available )); then
    selected_signature="$console_signature"
    selected_state="$console_state"
    GFN_LOG_FILE="$GFN_CONSOLE_LOG"
    GFN_LOG_SOURCE_KEY="console"
  elif (( debug_available && console_available )); then
    if [[ -n "$console_state" && -z "$debug_state" ]]; then
      selected_signature="$console_signature"
      selected_state="$console_state"
      GFN_LOG_FILE="$GFN_CONSOLE_LOG"
      GFN_LOG_SOURCE_KEY="console"
    elif [[ -n "$console_state" && -n "$debug_state" ]]; then
      if [[ -n "$console_candidate_time" && -z "$debug_candidate_time" ]] \
          || [[ -n "$console_candidate_time" && -n "$debug_candidate_time" \
             && "x$console_candidate_time" > "x$debug_candidate_time" ]]; then
        selected_signature="$console_signature"
        selected_state="$console_state"
        GFN_LOG_FILE="$GFN_CONSOLE_LOG"
        GFN_LOG_SOURCE_KEY="console"
      fi
    fi
  elif (( !debug_available && !console_available )); then
    selected_signature="missing"
  fi

  if [[ "$clock_source_key" == debug ]]; then
    GFN_LOG_FILE="$GFN_DEBUG_LOG"
    GFN_LOG_SOURCE_KEY=debug
    selected_state="$debug_state"
    selected_signature="$debug_signature"
  elif [[ "$clock_source_key" == console ]]; then
    GFN_LOG_FILE="$GFN_CONSOLE_LOG"
    GFN_LOG_SOURCE_KEY=console
    selected_state="$console_state"
    selected_signature="$console_signature"
  fi
  selected_source_available=0
  [[ "$selected_signature" == missing || "$selected_signature" == unreadable ]] \
    || selected_source_available=1
  selected_source_has_evidence=0
  [[ -n "$selected_state" ]] && selected_source_has_evidence=1
  if [[ -z "$selected_state" ]] \
      && { [[ "$GFN_LOG_SOURCE_KEY" == debug && -n "$debug_candidate_state" ]] \
        || [[ "$GFN_LOG_SOURCE_KEY" == console && -n "$console_candidate_state" ]]; }; then
    selected_source_suppressed=1
  fi
  selected_source_untrusted=0
  selected_signature_out="$selected_signature"
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
  local proof_fd saved_epoch proof_version proof_source_key proof_identity proof_size proof_event_time proof_clock_key
  local proof_clock_revision proof_debug_baseline proof_console_baseline extra
  local prefix_data="" suffix_data="" chunk_size bytes_read legacy_proof=0
  local baseline_pattern='^(active|inactive)?[|]([0-9]{17})?$'
  { exec {proof_fd}< "$STATE_FILE"; } 2>/dev/null || return 1
  {
    IFS= read -r -u "$proof_fd" saved_epoch || return 1
    IFS=' ' read -r -u "$proof_fd" proof_version proof_source_key proof_identity proof_size proof_event_time \
      proof_clock_key proof_clock_revision proof_debug_baseline proof_console_baseline extra || return 1
    [[ "$saved_epoch" =~ ^[0-9]+$ && ${#saved_epoch} -le 18 ]] || return 1
    if [[ "$proof_version" == source-v1 ]]; then
      # Old state has no source path or event watermark. It remains usable for
      # its recorded identity, but an alternate source cannot prove an end.
      legacy_proof=1
      proof_size="$proof_identity"
      proof_identity="$proof_source_key"
      proof_source_key="legacy"
      proof_event_time="-"
      [[ -z "$proof_clock_key$proof_clock_revision$proof_debug_baseline$proof_console_baseline$extra" ]] || return 1
    elif [[ ( "$proof_version" == source-v2 || "$proof_version" == source-v3 ) \
       && "$proof_source_key" =~ ^[A-Za-z0-9_.-]+$ \
       && "$proof_identity" =~ ^[0-9]{1,18}:[0-9]{1,18}$ \
       && "$proof_size" =~ ^[0-9]+$ && ${#proof_size} -le 18 \
       && ( "$proof_event_time" == - || "$proof_event_time" =~ ^[0-9]{17}$ ) \
       && -z "$extra" ]]; then
      if [[ "$proof_version" == source-v3 ]]; then
        [[ "$proof_clock_key" == - || "$proof_clock_key" == debug || "$proof_clock_key" == console ]] || return 1
        [[ -z "$proof_clock_revision$proof_debug_baseline$proof_console_baseline" ]] || return 1
      else
        [[ -z "$proof_clock_key" ]] || return 1
      fi
      legacy_proof=0
    elif [[ "$proof_version" == source-v4 \
       && "$proof_source_key" =~ ^[A-Za-z0-9_.-]+$ \
       && "$proof_identity" =~ ^[0-9]{1,18}:[0-9]{1,18}$ \
       && "$proof_size" =~ ^[0-9]+$ && ${#proof_size} -le 18 \
       && ( "$proof_event_time" == - || "$proof_event_time" =~ ^[0-9]{17}$ ) \
       && ( "$proof_clock_key" == - || "$proof_clock_key" == debug || "$proof_clock_key" == console ) \
       && "$proof_clock_revision" =~ ^(0|[1-9][0-9]{0,17})$ \
       && ( "$proof_debug_baseline" == - || "$proof_debug_baseline" =~ "$baseline_pattern" ) \
       && ( "$proof_console_baseline" == - || "$proof_console_baseline" =~ "$baseline_pattern" ) \
       && -z "$extra" ]]; then
      legacy_proof=0
    else
      return 1
    fi
    if (( legacy_proof )); then
      [[ "$proof_identity" =~ ^[0-9]{1,18}:[0-9]{1,18}$ \
         && "$proof_size" =~ ^[0-9]+$ && ${#proof_size} -le 18 \
         && -z "$extra" ]] || return 1
    fi
    chunk_size=$(( proof_size < CHECKPOINT_BYTES ? proof_size : CHECKPOINT_BYTES ))
    if (( chunk_size > 0 )); then
      sysread -i "$proof_fd" -s "$chunk_size" -c bytes_read prefix_data || return 1
      (( bytes_read == chunk_size )) || return 1
      sysread -i "$proof_fd" -s "$chunk_size" -c bytes_read suffix_data || return 1
      (( bytes_read == chunk_size )) || return 1
    fi
    if [[ "$proof_version" == source-v3 && "$proof_clock_key" != - ]]; then
      clock_source_key="$proof_clock_key"
    fi
    if [[ "$proof_version" == source-v4 ]]; then
      clock_source_key="${proof_clock_key/-/}"
      clock_debug_baseline="${proof_debug_baseline/-/}"
      clock_console_baseline="${proof_console_baseline/-/}"
      clock_revision="$proof_clock_revision"
      clock_pending_payload="$proof_clock_key $proof_debug_baseline $proof_console_baseline"
      owned_clock_revision="$proof_clock_revision"
    elif [[ "$proof_version" == source-v3 && "$proof_clock_key" != - ]]; then
      clock_revision=0
      clock_pending_payload="$proof_clock_key - -"
      # Legacy source proofs have no ordering metadata; an independent
      # guard-clock record must retain the pre-v4 restore behavior.
      owned_clock_revision=-1
    else
      owned_clock_revision=-1
    fi
    parsed_identity="$proof_identity"
    parsed_size="$proof_size"
    parsed_stream_state="active"
    parsed_event_time="${proof_event_time/-/}"
    parsed_source_key="$proof_source_key"
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
      if (( source_proof_ready )) && [[ -n "$parsed_signature" \
          && -n "$GFN_LOG_SOURCE_KEY" \
          && ( "$parsed_event_time" == - || "$parsed_event_time" =~ ^[0-9]{17}$ ) ]]; then
        if [[ -n "$clock_pending_payload$clock_saved_snapshot" || "$clock_revision" != 0 ]]; then
          print -r -- "source-v4 $GFN_LOG_SOURCE_KEY $parsed_identity $parsed_size $parsed_event_time ${clock_source_key:--} $clock_revision ${clock_debug_baseline:--} ${clock_console_baseline:--}" \
            && print -rn -- "$parsed_prefix$parsed_suffix"
        else
          print -r -- "source-v3 $GFN_LOG_SOURCE_KEY $parsed_identity $parsed_size $parsed_event_time ${clock_source_key:--}" \
            && print -rn -- "$parsed_prefix$parsed_suffix"
        fi
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
    [[ -n "$detected_stream_state" ]] && selected_source_has_evidence=1
    if [[ "$detected_stream_state" == "active" ]]; then
      current_stream_state="active"
    elif [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      # If rotation/removal temporarily hides the session markers, the
      # private state file keeps the lease alive until evidence returns.
      current_stream_state="active"
    fi
    if (( selected_source_untrusted )) || (( !selected_source_available )); then
      raise_alert "gfn-log-unavailable" "$now_epoch" \
        "GeForce NOW is running, but its session logs are unavailable; backups may not be paused." \
        "GeForce NOW działa, ale jego logi sesji są niedostępne; backup może nie być wstrzymany."
    elif (( !selected_source_has_evidence )); then
      raise_alert "gfn-log-state-unknown" "$now_epoch" \
        "GeForce NOW is running, but no recognized session state was found; backups may not be paused." \
        "GeForce NOW działa, ale nie znaleziono rozpoznanego stanu sesji; backup może nie być wstrzymany."
    elif [[ "$detected_stream_state" == inactive \
        || "$detected_stream_state" == active ]]; then
      clear_detection_alert
    fi
  elif [[ "$process_state" == "unknown" ]]; then
    log_message "WARN: could not determine whether the GFN process is running"
    latest_stream_state "$source_signature"
    detected_stream_state="$detected_stream_state_out"
    [[ -n "$detected_stream_state" ]] && selected_source_has_evidence=1
    if [[ "$detected_stream_state" == "active" ]] \
        || [[ -f "$STATE_FILE" && "$detected_stream_state" != "inactive" ]]; then
      current_stream_state="active"
    fi
    if (( selected_source_untrusted )) || (( !selected_source_available )) \
        || (( !selected_source_has_evidence )); then
      raise_alert "gfn-log-process-unknown" "$now_epoch" \
        "Could not determine whether GeForce NOW is running; session protection is unavailable." \
        "Nie udało się ustalić, czy GeForce NOW działa; ochrona sesji jest niedostępna."
    elif [[ "$detected_stream_state" == inactive \
        || "$detected_stream_state" == active ]]; then
      clear_detection_alert
    fi
  else
    # Do not carry old stream evidence into a new launcher process after
    # a crash/quit. Its startup rotation may retain an old active .bak.
    clock_source_key=""
    clock_source_dirty=0
    stopped_debug_evidence="$debug_candidate_state|$debug_candidate_time"
    stopped_console_evidence="$console_candidate_state|$console_candidate_time"
    if [[ -n "$GFN_LOG_OVERRIDE" && "$source_signature" != "$stopped_explicit_signature" \
        && "$source_signature" != missing && "$source_signature" != unreadable ]]; then
      stopped_explicit_evidence="$(parse_stream_evidence --watermark "$GFN_LOG_FILE" 2>/dev/null)" \
        || stopped_explicit_evidence=""
    fi
    stopped_explicit_signature="$source_signature"
    parsed_signature=""
    parsed_identity=""
    parsed_size=0
    parsed_stream_state=""
    parsed_prefix=""
    parsed_suffix=""
    source_proof_ready=0
    [[ -f "$STATE_FILE" ]] || clear_alert_episode
  fi

  if [[ "$detected_stream_state" == inactive && -n "$clock_source_key" ]]; then
    # End this clock episode without reviving the alternate source's older
    # start/end. New evidence there can participate in the next session.
    if [[ "$clock_source_key" == debug ]]; then
      clock_console_baseline="$console_candidate_state|$console_candidate_time"
      clock_debug_baseline=""
    else
      clock_debug_baseline="$debug_candidate_state|$debug_candidate_time"
      clock_console_baseline=""
    fi
    clock_source_key=""
    clock_source_dirty=0
  fi

  write_clock_state || true

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

    # Persist an observed clock-source change immediately with a renewed
    # lease; waiting four minutes would lose this ordering proof on restart.
    (( clock_source_dirty )) && previous_renewal=0
    if (( now_epoch - previous_renewal >= RENEW_SECONDS )); then
      if run_arqc pauseBackups "$PAUSE_MINUTES"; then
        if write_state_timestamp "$now_epoch"; then
          clock_source_dirty=0
          clear_action_alert
          log_message "GFN stream active; Arq pause renewed for $PAUSE_MINUTES minutes"
          if (( first_pause )); then
            notify_user \
              "Backup paused for the active GeForce NOW session." \
              "Backup wstrzymany na czas aktywnej sesji GeForce NOW."
          fi
        else
          log_message "WARN: Arq is paused but guard state was not saved; pause will expire automatically"
          raise_alert "state-save-failure" "$now_epoch" \
            "Arq was paused, but the guard could not save its recovery state." \
            "Arq został wstrzymany, ale guard nie zapisał stanu potrzebnego do wznowienia." 1
        fi
      else
        raise_alert "pause-failure" "$now_epoch" \
          "GeForce NOW is active, but Arq backups could not be paused." \
          "GeForce NOW jest aktywny, ale nie udało się wstrzymać backupu Arq." 1
      fi
    fi
  elif [[ -f "$STATE_FILE" ]]; then
    # Arq exposes one global pause and no supported CLI readback for the pause
    # that existed before this guard acted. The state file proves that this
    # guard successfully issued a pause, but overlapping independent manual
    # pauses are intentionally documented as unsupported.
    if run_arqc resumeBackups; then
      rm -f "$STATE_FILE"
      clear_alert_episode
      log_message "GFN stream inactive; Arq resumed"
      notify_user \
        "GeForce NOW session ended; backup resumed." \
        "Sesja GeForce NOW zakończona; backup wznowiony."
    else
      raise_alert "resume-failure" "$now_epoch" \
        "The GeForce NOW session ended, but Arq backups could not be resumed." \
        "Sesja GeForce NOW się zakończyła, ale nie udało się wznowić backupu Arq." 1
    fi
  elif [[ "$process_state" == "running" \
      && "$detected_stream_state" == "inactive" ]]; then
    clear_action_alert
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
restore_clock_state || true
restore_alert_episode

last_signature=""
iterations_since_reconcile=$SAFETY_ITERATIONS

while true; do
  select_log_source
  # Keep evidence paired with the signature observed before its read. A write
  # during selection must remain a change for the next iteration, not label
  # old evidence with a newer signature and hide it behind the parsed cache.
  current_signature="$selected_signature_out"
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
