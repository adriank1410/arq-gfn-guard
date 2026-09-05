#!/bin/zsh

set -eu
unsetopt bg_nice

readonly TEST_DIR="${0:A:h}"
readonly SCRIPT_DIR="${TEST_DIR:h}"
readonly GUARD_SCRIPT="$SCRIPT_DIR/arq-gfn-guard.sh"
readonly GUARD_PLIST="$SCRIPT_DIR/com.local.arq-gfn-guard.plist"
readonly INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
readonly UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
readonly TEST_ROOT="$(mktemp -d /tmp/arq-gfn-guard-test.XXXXXX)"
monitor_pid=""

cleanup() {
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

run_guard() {
  ARQ_GFN_GUARD_DRY_RUN=1 \
  ARQ_GFN_FORCE_PROCESS="$1" \
  ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
  ARQ_GFN_STATE_DIR="$TEST_ROOT/state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
  ARQ_GFN_NOW="$2" \
  ARQ_GFN_GUARD_ONCE=1 \
  "$GUARD_SCRIPT"
}

start_monitor() {
  ARQ_GFN_GUARD_DRY_RUN=1 \
  ARQ_GFN_FORCE_PROCESS=1 \
  ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
  ARQ_GFN_STATE_DIR="$TEST_ROOT/state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
  ARQ_GFN_LOOP_SECONDS=1 \
  ARQ_GFN_SAFETY_SECONDS="${1:-2}" \
  "${2:-$GUARD_SCRIPT}" &
  monitor_pid=$!
}

assert_file_exists() {
  [[ -f "$1" ]] || { print -u2 -- "Expected file to exist: $1"; exit 1; }
}

assert_file_missing() {
  [[ ! -e "$1" ]] || { print -u2 -- "Expected file to be absent: $1"; exit 1; }
}

assert_log_contains() {
  /usr/bin/grep -Fq -- "$1" "$TEST_ROOT/guard.log" || {
    print -u2 -- "Expected guard log to contain: $1"
    exit 1
  }
}

wait_for_log() {
  local expected="$1"
  local attempt=0
  while (( attempt < 50 )); do
    if [[ -f "$TEST_ROOT/guard.log" ]] \
        && /usr/bin/grep -Fq -- "$expected" "$TEST_ROOT/guard.log"; then
      return 0
    fi
    /bin/sleep 0.1
    attempt=$(( attempt + 1 ))
  done
  print -u2 -- "Timed out waiting for guard log: $expected"
  return 1
}

zsh -n "$GUARD_SCRIPT" "$INSTALL_SCRIPT" "$UNINSTALL_SCRIPT"
/usr/bin/plutil -lint "$GUARD_PLIST" >/dev/null
[[ "$(/usr/bin/plutil -extract KeepAlive raw -o - "$GUARD_PLIST")" == "true" ]] || {
  print -u2 -- "LaunchAgent must keep the monitor alive"
  exit 1
}
if /usr/bin/plutil -extract WatchPaths raw -o - "$GUARD_PLIST" >/dev/null 2>&1 \
    || /usr/bin/plutil -extract StartInterval raw -o - "$GUARD_PLIST" >/dev/null 2>&1; then
  print -u2 -- "Persistent monitor must not also use WatchPaths or StartInterval"
  exit 1
fi
[[ "$(/usr/bin/plutil -extract EnvironmentVariables.ARQ_GFN_NOTIFICATIONS raw -o - "$GUARD_PLIST")" == "0" ]] || {
  print -u2 -- "Notifications must be disabled by default in the LaunchAgent"
  exit 1
}
[[ "$(/usr/bin/plutil -extract EnvironmentVariables.ARQ_GFN_LOOP_SECONDS raw -o - "$GUARD_PLIST")" == "2" ]] || {
  print -u2 -- "LaunchAgent must expose the two-second loop default"
  exit 1
}
[[ "$(/usr/bin/plutil -extract EnvironmentVariables.ARQ_GFN_SAFETY_SECONDS raw -o - "$GUARD_PLIST")" == "60" ]] || {
  print -u2 -- "LaunchAgent must expose the 60-second safety default"
  exit 1
}

rendered_plist="$TEST_ROOT/rendered.plist"
/bin/cp "$GUARD_PLIST" "$rendered_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $TEST_ROOT/arq-gfn-guard.sh" "$rendered_plist"
/usr/bin/plutil -replace StandardOutPath -string "$TEST_ROOT/launchd.out.log" "$rendered_plist"
/usr/bin/plutil -replace StandardErrorPath -string "$TEST_ROOT/launchd.err.log" "$rendered_plist"
/usr/bin/plutil -lint "$rendered_plist" >/dev/null
if /usr/bin/grep -Fq -- '__ARQ_GFN_' "$rendered_plist"; then
  print -u2 -- "Rendered LaunchAgent still contains a template placeholder"
  exit 1
fi

for public_file in "$GUARD_SCRIPT" "$GUARD_PLIST" "$INSTALL_SCRIPT" \
    "$UNINSTALL_SCRIPT" "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/README.pl.md"; do
  if /usr/bin/grep -Fq -- '/Users/' "$public_file"; then
    print -u2 -- "Public file contains a machine-specific home path: $public_file"
    exit 1
  fi
done
/usr/bin/grep -Fq -- 'off by default' "$SCRIPT_DIR/README.md" || {
  print -u2 -- "English README must document silent-by-default behavior"
  exit 1
}
/usr/bin/grep -Fq -- 'Domyślnie działa **bez powiadomień**' "$SCRIPT_DIR/README.pl.md" || {
  print -u2 -- "Polish README must document silent-by-default behavior"
  exit 1
}
if /usr/bin/grep -Fq -- 'not an unrelated user pause' "$SCRIPT_DIR/README.md"; then
  print -u2 -- "English README must not claim that global manual Arq pauses are preserved"
  exit 1
fi
if /usr/bin/grep -Fq -- 'a nie niezależną pauzę użytkownika' "$SCRIPT_DIR/README.pl.md"; then
  print -u2 -- "Polish README must not claim that global manual Arq pauses are preserved"
  exit 1
fi
/usr/bin/grep -Fq -- 'overlapping an independent manual Arq pause is unsupported' "$SCRIPT_DIR/README.md" || {
  print -u2 -- "English README must document the global-pause limitation"
  exit 1
}
/usr/bin/grep -Fq -- 'łączenie sesji GFN z niezależną ręczną pauzą Arq nie jest obsługiwane' "$SCRIPT_DIR/README.pl.md" || {
  print -u2 -- "Polish README must document the global-pause limitation"
  exit 1
}

# Notifications are opt-in. When enabled, their language can be forced to EN
# or PL; messages are passed to AppleScript as argv, never interpolated code.
fake_osascript="$TEST_ROOT/fake-osascript"
fake_defaults="$TEST_ROOT/fake-defaults"
notification_guard="$TEST_ROOT/notification-guard.zsh"
print '#!/bin/zsh' > "$fake_osascript"
print 'print -r -- "$*" >> "$FAKE_OSASCRIPT_LOG"' >> "$fake_osascript"
chmod +x "$fake_osascript"
print '#!/bin/zsh' > "$fake_defaults"
print 'print -r -- pl_PL' >> "$fake_defaults"
chmod +x "$fake_defaults"
/usr/bin/sed -e "s#/usr/bin/osascript#$fake_osascript#g" \
  -e "s#/usr/bin/defaults#$fake_defaults#g" \
  "$GUARD_SCRIPT" > "$notification_guard"
chmod +x "$notification_guard"

run_notification_guard() {
  local notifications="$1" language="$2" now_epoch="$3"
  ARQ_GFN_ARQC=/usr/bin/true \
  ARQ_GFN_NOTIFICATIONS="$notifications" \
  ARQ_GFN_LANG="$language" \
  ARQ_GFN_FORCE_PROCESS=1 \
  ARQ_GFN_LOG_FILE="$TEST_ROOT/notification-gfn.log" \
  ARQ_GFN_STATE_DIR="$TEST_ROOT/notification-state" \
  ARQ_GFN_GUARD_LOG="$TEST_ROOT/notification.log" \
  ARQ_GFN_NOW="$now_epoch" \
  ARQ_GFN_GUARD_ONCE=1 \
  FAKE_OSASCRIPT_LOG="$TEST_ROOT/osascript.calls" \
  "$notification_guard"
}

: > "$TEST_ROOT/osascript.calls"
print -r -- "IPC_STREAMING_PREPARE_EVENT" > "$TEST_ROOT/notification-gfn.log"
run_notification_guard 0 en 8000
[[ ! -s "$TEST_ROOT/osascript.calls" ]] || {
  print -u2 -- "Disabled notifications must stay silent"
  exit 1
}

rm -f "$TEST_ROOT/notification-state/guard-paused"
: > "$TEST_ROOT/osascript.calls"
run_notification_guard 1 en 8100
/usr/bin/grep -Fq -- "Backup paused for the active GeForce NOW session." "$TEST_ROOT/osascript.calls" || {
  print -u2 -- "English pause notification missing"
  exit 1
}
run_notification_guard 1 en 8110
[[ "$(/usr/bin/wc -l < "$TEST_ROOT/osascript.calls" | /usr/bin/tr -d ' ')" == "1" ]] || {
  print -u2 -- "Pause renewal must not repeat the notification"
  exit 1
}
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" >> "$TEST_ROOT/notification-gfn.log"
run_notification_guard 1 en 8120
/usr/bin/grep -Fq -- "GeForce NOW session ended; backup resumed." "$TEST_ROOT/osascript.calls" || {
  print -u2 -- "English resume notification missing"
  exit 1
}

rm -f "$TEST_ROOT/notification-state/guard-paused"
: > "$TEST_ROOT/osascript.calls"
print -r -- "IPC_STREAMING_PREPARE_EVENT" > "$TEST_ROOT/notification-gfn.log"
run_notification_guard 1 pl 8200
/usr/bin/grep -Fq -- "Backup wstrzymany na czas aktywnej sesji GeForce NOW." "$TEST_ROOT/osascript.calls" || {
  print -u2 -- "Polish pause notification missing"
  exit 1
}

rm -f "$TEST_ROOT/notification-state/guard-paused"
: > "$TEST_ROOT/osascript.calls"
run_notification_guard 1 '' 8300
/usr/bin/grep -Fq -- "Backup wstrzymany na czas aktywnej sesji GeForce NOW." "$TEST_ROOT/osascript.calls" || {
  print -u2 -- "Automatic Polish locale detection failed"
  exit 1
}

if ARQ_GFN_NOTIFICATIONS=invalid ARQ_GFN_GUARD_ONCE=1 \
    "$GUARD_SCRIPT" >/dev/null 2>&1; then
  print -u2 -- "Invalid notification toggle must fail"
  exit 1
fi
if ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=invalid ARQ_GFN_GUARD_ONCE=1 \
    "$GUARD_SCRIPT" >/dev/null 2>&1; then
  print -u2 -- "Invalid notification language must fail"
  exit 1
fi

print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 1 1000
assert_file_exists "$TEST_ROOT/state/guard-paused"
assert_log_contains "DRY-RUN arqc pauseBackups 10"
[[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT/state/guard-paused")" == "600" ]] || {
  print -u2 -- "State file must be private (mode 600)"
  exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT/state")" == "700" ]] || {
  print -u2 -- "State directory must be private (mode 700)"
  exit 1
}
if /usr/bin/find "$TEST_ROOT/state" -maxdepth 1 -name '.guard-paused.*' | /usr/bin/grep -q .; then
  print -u2 -- "Atomic state write left a temporary file behind"
  exit 1
fi

print -r -- "IPC_STREAMING_TERMINATED_EVENT" >> "$TEST_ROOT/gfn.log"
run_guard 1 1015
assert_file_missing "$TEST_ROOT/state/guard-paused"
assert_log_contains "DRY-RUN arqc resumeBackups"

# A transient process-query failure must fail safe. If the guard already owns
# an active pause lease, it must not resume Arq until it can prove that the GFN
# process is gone.
: > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 1 1100
run_guard error 1115
assert_file_exists "$TEST_ROOT/state/guard-paused"
assert_log_contains "could not determine whether the GFN process is running"
run_guard 0 1130
assert_file_missing "$TEST_ROOT/state/guard-paused"
assert_log_contains "DRY-RUN arqc resumeBackups"

# An arqc failure must be visible and must not make ownership state lie: a
# failed pause cannot create state, while a failed resume must retain it so the
# next reconciliation retries instead of assuming backups are active.
fake_arqc="$TEST_ROOT/arqc-fail"
print '#!/bin/zsh' > "$fake_arqc"
print 'exit 42' >> "$fake_arqc"
chmod +x "$fake_arqc"

rm -rf "$TEST_ROOT/failure-state"
: > "$TEST_ROOT/failure.log"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
ARQ_GFN_ARQC="$fake_arqc" \
ARQ_GFN_FORCE_PROCESS=1 \
ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
ARQ_GFN_STATE_DIR="$TEST_ROOT/failure-state" \
ARQ_GFN_GUARD_LOG="$TEST_ROOT/failure.log" \
ARQ_GFN_NOW=1200 \
ARQ_GFN_GUARD_ONCE=1 \
"$GUARD_SCRIPT"
assert_file_missing "$TEST_ROOT/failure-state/guard-paused"
/usr/bin/grep -Fq -- "ERROR: arqc pauseBackups failed with exit code 42" "$TEST_ROOT/failure.log" || {
  print -u2 -- "Failed arqc pause must be logged"
  exit 1
}

print -r -- 1200 > "$TEST_ROOT/failure-state/guard-paused"
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" > "$TEST_ROOT/gfn.log"
ARQ_GFN_ARQC="$fake_arqc" \
ARQ_GFN_FORCE_PROCESS=1 \
ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
ARQ_GFN_STATE_DIR="$TEST_ROOT/failure-state" \
ARQ_GFN_GUARD_LOG="$TEST_ROOT/failure.log" \
ARQ_GFN_NOW=1215 \
ARQ_GFN_GUARD_ONCE=1 \
"$GUARD_SCRIPT"
assert_file_exists "$TEST_ROOT/failure-state/guard-paused"
/usr/bin/grep -Fq -- "ERROR: arqc resumeBackups failed with exit code 42" "$TEST_ROOT/failure.log" || {
  print -u2 -- "Failed arqc resume must be logged"
  exit 1
}

: > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_PREPARE_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 1 2000
assert_file_exists "$TEST_ROOT/state/guard-paused"
assert_log_contains "DRY-RUN arqc pauseBackups 10"

rm -f "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 0 3000
assert_file_missing "$TEST_ROOT/state/guard-paused"
if [[ -s "$TEST_ROOT/guard.log" ]]; then
  print -u2 -- "Guard must not pause when the GFN UI process is absent"
  exit 1
fi

: > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 1 4000
run_guard 1 4030
pause_count="$(/usr/bin/grep -Fc 'DRY-RUN arqc pauseBackups 10' "$TEST_ROOT/guard.log")"
[[ "$pause_count" == "1" ]] || {
  print -u2 -- "Expected one pause renewal within 240 seconds, got $pause_count"
  exit 1
}

run_guard 1 4240
pause_count="$(/usr/bin/grep -Fc 'DRY-RUN arqc pauseBackups 10' "$TEST_ROOT/guard.log")"
[[ "$pause_count" == "2" ]] || {
  print -u2 -- "Expected a pause renewal at the 240-second boundary, got $pause_count"
  exit 1
}

# A truncated or corrupted timestamp must not break the guard or be evaluated
# as a zsh arithmetic expression. It should be replaced by a fresh timestamp.
print -r -- 'not-a-timestamp' > "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
run_guard 1 5000
[[ "$(<"$TEST_ROOT/state/guard-paused")" == "5000" ]] || {
  print -u2 -- "Corrupt state timestamp was not repaired"
  exit 1
}
assert_log_contains "invalid state timestamp"

# A digits-only but out-of-range value must also be rejected before zsh tries
# to interpret it as an integer and silently truncates it.
print -r -- '9999999999999999999999999999999999999999' > "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
run_guard 1 5100
[[ "$(<"$TEST_ROOT/state/guard-paused")" == "5100" ]] || {
  print -u2 -- "Out-of-range state timestamp was not repaired"
  exit 1
}
assert_log_contains "invalid state timestamp"

# A wall-clock correction must not let a future renewal timestamp suppress
# lease renewal until the clock catches up.
print -r -- '9000' > "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
run_guard 1 5000
[[ "$(<"$TEST_ROOT/state/guard-paused")" == "5000" ]] || {
  print -u2 -- "Future state timestamp was not repaired"
  exit 1
}
assert_log_contains "state timestamp is in the future"

# Test-only time overrides are validated too, so malformed input fails clearly
# without invoking arqc or creating state.
rm -f "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
if ARQ_GFN_GUARD_DRY_RUN=1 \
    ARQ_GFN_FORCE_PROCESS=1 \
    ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
    ARQ_GFN_STATE_DIR="$TEST_ROOT/state" \
    ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
    ARQ_GFN_NOW='invalid' \
    ARQ_GFN_GUARD_ONCE=1 \
    "$GUARD_SCRIPT"; then
  print -u2 -- "Invalid current time must fail"
  exit 1
fi
assert_file_missing "$TEST_ROOT/state/guard-paused"
assert_log_contains "invalid current timestamp"

rm -f "$TEST_ROOT/state/guard-paused"
: > "$TEST_ROOT/guard.log"
if ARQ_GFN_GUARD_DRY_RUN=1 \
    ARQ_GFN_FORCE_PROCESS=1 \
    ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
    ARQ_GFN_STATE_DIR="$TEST_ROOT/state" \
    ARQ_GFN_GUARD_LOG="$TEST_ROOT/guard.log" \
    ARQ_GFN_NOW='9999999999999999999999999999999999999999' \
    ARQ_GFN_GUARD_ONCE=1 \
    "$GUARD_SCRIPT"; then
  print -u2 -- "Out-of-range current time must fail"
  exit 1
fi
assert_file_missing "$TEST_ROOT/state/guard-paused"
assert_log_contains "invalid current timestamp"

# zsh/datetime's EPOCHSECONDS can briefly remain stale after DarkWake on
# macOS. Simulate a fresh kernel clock by replacing /bin/date in a test copy;
# the pause timestamp must come from that clock, not EPOCHSECONDS.
fake_date="$TEST_ROOT/fake-date"
fresh_clock_guard="$TEST_ROOT/fresh-clock-guard.zsh"
print '#!/bin/zsh' > "$fake_date"
print 'print -r -- "$*" >> "$FAKE_DATE_CALL_LOG"' >> "$fake_date"
print '[[ "$1" == "+%s" ]] && { print -r -- 7000; exit 0; }' >> "$fake_date"
print 'print -r -- TEST_TIME' >> "$fake_date"
chmod +x "$fake_date"
/usr/bin/sed "s#/bin/date#$fake_date#g" "$GUARD_SCRIPT" > "$fresh_clock_guard"
chmod +x "$fresh_clock_guard"
: > "$TEST_ROOT/date.calls"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
ARQ_GFN_GUARD_DRY_RUN=1 \
ARQ_GFN_FORCE_PROCESS=1 \
ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
ARQ_GFN_STATE_DIR="$TEST_ROOT/fresh-clock-state" \
ARQ_GFN_GUARD_LOG="$TEST_ROOT/fresh-clock.log" \
ARQ_GFN_GUARD_ONCE=1 \
FAKE_DATE_CALL_LOG="$TEST_ROOT/date.calls" \
"$fresh_clock_guard"
[[ "$(<"$TEST_ROOT/fresh-clock-state/guard-paused")" == "7000" ]] || {
  print -u2 -- "Guard did not use a fresh wall-clock timestamp"
  exit 1
}

# Reading the fresh wall clock should happen only during reconciliation, not
# every two-second idle iteration. This keeps the persistent monitor cheap.
rm -f "$TEST_ROOT/fresh-clock-state/guard-paused"
: > "$TEST_ROOT/date.calls"
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" > "$TEST_ROOT/gfn.log"
ARQ_GFN_GUARD_DRY_RUN=1 \
ARQ_GFN_FORCE_PROCESS=0 \
ARQ_GFN_LOG_FILE="$TEST_ROOT/gfn.log" \
ARQ_GFN_STATE_DIR="$TEST_ROOT/fresh-clock-state" \
ARQ_GFN_GUARD_LOG="$TEST_ROOT/fresh-clock.log" \
ARQ_GFN_LOOP_SECONDS=1 \
ARQ_GFN_SAFETY_SECONDS=100 \
FAKE_DATE_CALL_LOG="$TEST_ROOT/date.calls" \
"$fresh_clock_guard" &
monitor_pid=$!
/bin/sleep 2.2
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""
date_call_count="$(/usr/bin/grep -Fc '+%s' "$TEST_ROOT/date.calls" || true)"
[[ "$date_call_count" == "1" ]] || {
  print -u2 -- "Expected one fresh-clock read while idle, got $date_call_count"
  exit 1
}

# Existing logs from an older install are made private even when the current
# check has nothing new to write.
: > "$TEST_ROOT/guard.log"
chmod 644 "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 0 5900
[[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT/guard.log")" == "600" ]] || {
  print -u2 -- "Existing guard log must be made private at startup"
  exit 1
}

# Log rotation must replace the log atomically and clean up its temporary file.
/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\0' 'x' > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 0 6000
(( $(/usr/bin/stat -f '%z' "$TEST_ROOT/guard.log") < 300000 )) || {
  print -u2 -- "Guard log was not rotated"
  exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT/guard.log")" == "600" ]] || {
  print -u2 -- "Rotated guard log must be private (mode 600)"
  exit 1
}
if /usr/bin/find "$TEST_ROOT" -maxdepth 1 -name '.guard.log.*' | /usr/bin/grep -q .; then
  print -u2 -- "Atomic log rotation left a temporary file behind"
  exit 1
fi

# Integration: one persistent instance notices start/end writes without being
# relaunched by launchd and keeps its fallback safety loop alive.
: > "$TEST_ROOT/gfn.log"
: > "$TEST_ROOT/guard.log"
start_monitor
/bin/sleep 0.2
kill -0 "$monitor_pid" 2>/dev/null || {
  print -u2 -- "Persistent guard exited unexpectedly"
  exit 1
}
print -r -- "IPC_STREAMING_PREPARE_EVENT" >> "$TEST_ROOT/gfn.log"
wait_for_log "GFN stream active; Arq pause renewed for 10 minutes"
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" >> "$TEST_ROOT/gfn.log"
wait_for_log "GFN stream inactive; Arq resumed"
kill "$monitor_pid"
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""

# Rotation can replace a log with the same size and mtime. Both stat paths
# must notice the new file before the safety reconciliation becomes due.
fallback_guard="$TEST_ROOT/fallback-guard.zsh"
/usr/bin/sed 's@zmodload zsh/stat@zmodload zsh/arq_gfn_missing_stat@' \
  "$GUARD_SCRIPT" > "$fallback_guard"
chmod +x "$fallback_guard"
for rotation_guard in "$GUARD_SCRIPT" "$fallback_guard"; do
  : > "$TEST_ROOT/guard.log"
  printf '%-80s\n' 'IPC_STREAMING_MODE_EXIT_EVENT' > "$TEST_ROOT/gfn.log"
  start_monitor 100 "$rotation_guard"
  /bin/sleep 1.2
  for marker in IPC_STREAMING_STARTED_EVENT IPC_STREAMING_MODE_EXIT_EVENT; do
    printf '%-80s\n' "$marker" > "$TEST_ROOT/replacement.log"
    /usr/bin/touch -r "$TEST_ROOT/gfn.log" "$TEST_ROOT/replacement.log"
    [[ "$(/usr/bin/stat -f '%m:%z' "$TEST_ROOT/gfn.log")" == \
       "$(/usr/bin/stat -f '%m:%z' "$TEST_ROOT/replacement.log")" ]] || {
      print -u2 -- "Rotation fixture must preserve size and mtime"
      exit 1
    }
    mv -f "$TEST_ROOT/replacement.log" "$TEST_ROOT/gfn.log"
    if [[ "$marker" == IPC_STREAMING_STARTED_EVENT ]]; then
      wait_for_log "GFN stream active; Arq pause renewed for 10 minutes"
      assert_file_exists "$TEST_ROOT/state/guard-paused"
    else
      wait_for_log "GFN stream inactive; Arq resumed"
      assert_file_missing "$TEST_ROOT/state/guard-paused"
    fi
  done
  kill "$monitor_pid"
  wait "$monitor_pid" 2>/dev/null || true
  monitor_pid=""
done

# A growing log can push the start marker outside the one-MiB scan window.
# Ownership must still renew the lease, then a new end marker must resume it.
: > "$TEST_ROOT/guard.log"
print -r -- "IPC_STREAMING_STARTED_EVENT" > "$TEST_ROOT/gfn.log"
run_guard 1 10000
/usr/bin/head -c 1048577 /dev/zero | /usr/bin/tr '\0' 'x' >> "$TEST_ROOT/gfn.log"
print >> "$TEST_ROOT/gfn.log"
run_guard 1 10240
[[ "$(<"$TEST_ROOT/state/guard-paused")" == "10240" ]] || {
  print -u2 -- "Growing log lost the owned pause lease"
  exit 1
}
print -r -- "IPC_STREAMING_MODE_EXIT_EVENT" >> "$TEST_ROOT/gfn.log"
run_guard 1 10250
assert_file_missing "$TEST_ROOT/state/guard-paused"
assert_log_contains "DRY-RUN arqc resumeBackups"

print -r -- "All Arq GFN guard tests passed"
