#!/bin/zsh
# Install arq-gfn-guard as a per-user LaunchAgent. Do not use sudo.

emulate -LR zsh
setopt err_exit nounset pipe_fail
umask 077

readonly SCRIPT_DIR="${0:A:h}"
readonly LABEL="com.local.arq-gfn-guard"
readonly SOURCE_SCRIPT="$SCRIPT_DIR/arq-gfn-guard.sh"
readonly SOURCE_PLIST="$SCRIPT_DIR/com.local.arq-gfn-guard.plist"
readonly DEST_DIR="$HOME/Library/Application Support/ArqGFNGuard"
readonly DEST_SCRIPT="$DEST_DIR/arq-gfn-guard.sh"
readonly DEST_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG_DIR="$HOME/Library/Logs/ArqGFNGuard"
readonly STDOUT_LOG="$LOG_DIR/launchd.out.log"
readonly STDERR_LOG="$LOG_DIR/launchd.err.log"

if (( ${+ARQ_GFN_NOTIFICATIONS} )); then
  notifications_value="$ARQ_GFN_NOTIFICATIONS"
else
  notifications_value="$(/usr/bin/plutil -extract EnvironmentVariables.ARQ_GFN_NOTIFICATIONS raw -o - "$DEST_PLIST" 2>/dev/null)" \
    || notifications_value="0"
fi
if (( ${+ARQ_GFN_LANG} )); then
  notification_language="$ARQ_GFN_LANG"
else
  notification_language="$(/usr/bin/plutil -extract EnvironmentVariables.ARQ_GFN_LANG raw -o - "$DEST_PLIST" 2>/dev/null)" \
    || notification_language=""
fi

install_language="${ARQ_GFN_INSTALL_LANG:-$notification_language}"
if [[ -z "$install_language" ]]; then
  install_language="$(/usr/bin/defaults read -g AppleLocale 2>/dev/null)" \
    || install_language="en"
fi

msg() {
  if [[ "$install_language" == pl* ]]; then
    print -r -- "$2"
  else
    print -r -- "$1"
  fi
}

if (( EUID == 0 )); then
  msg "Do not run with sudo; this is a per-user LaunchAgent." \
      "Nie uruchamiaj przez sudo; to LaunchAgent użytkownika."
  exit 1
fi
if [[ "$notifications_value" != "0" && "$notifications_value" != "1" ]]; then
  msg "ARQ_GFN_NOTIFICATIONS must be 0 or 1." \
      "ARQ_GFN_NOTIFICATIONS musi mieć wartość 0 albo 1."
  exit 2
fi
if [[ -n "$notification_language" \
    && "$notification_language" != en* \
    && "$notification_language" != pl* ]]; then
  msg "ARQ_GFN_LANG must be en, pl, or empty for auto-detection." \
      "ARQ_GFN_LANG musi mieć wartość en, pl albo być puste dla autodetekcji."
  exit 2
fi
if [[ ! -x "$SOURCE_SCRIPT" || ! -f "$SOURCE_PLIST" ]]; then
  msg "Installer files are incomplete." "Brakuje plików instalatora."
  exit 1
fi
if [[ ! -x /Applications/Arq.app/Contents/Resources/arqc ]]; then
  msg "Arq 7 was not found in /Applications." \
      "Nie znaleziono Arq 7 w katalogu /Applications."
  exit 1
fi
if [[ ! -d /Applications/GeForceNOW.app ]]; then
  msg "GeForce NOW was not found in /Applications." \
      "Nie znaleziono GeForce NOW w katalogu /Applications."
  exit 1
fi

/bin/launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
/bin/launchctl unload "$DEST_PLIST" 2>/dev/null || true

/bin/mkdir -p "$DEST_DIR" "${DEST_PLIST:h}" "$LOG_DIR"
/bin/chmod 700 "$DEST_DIR" "$LOG_DIR"
/usr/bin/install -m 700 "$SOURCE_SCRIPT" "$DEST_SCRIPT"
/bin/cp "$SOURCE_PLIST" "$DEST_PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $DEST_SCRIPT" "$DEST_PLIST"
/usr/bin/plutil -replace StandardOutPath -string "$STDOUT_LOG" "$DEST_PLIST"
/usr/bin/plutil -replace StandardErrorPath -string "$STDERR_LOG" "$DEST_PLIST"
/usr/bin/plutil -replace EnvironmentVariables.ARQ_GFN_NOTIFICATIONS -string "$notifications_value" "$DEST_PLIST"
/usr/bin/plutil -replace EnvironmentVariables.ARQ_GFN_LANG -string "$notification_language" "$DEST_PLIST"
/bin/chmod 644 "$DEST_PLIST"
/usr/bin/plutil -lint "$DEST_PLIST" >/dev/null

bootstrap_error=""
load_error=""
if ! bootstrap_error="$(/bin/launchctl bootstrap "gui/$UID" "$DEST_PLIST" 2>&1)"; then
  if ! load_error="$(/bin/launchctl load "$DEST_PLIST" 2>&1)"; then
    msg "launchctl bootstrap failed: $bootstrap_error" \
        "launchctl bootstrap nie powiódł się: $bootstrap_error"
    msg "launchctl load failed: $load_error" \
        "launchctl load nie powiódł się: $load_error"
    exit 1
  fi
fi

/bin/sleep 2
agent_info="$(/bin/launchctl print "gui/$UID/$LABEL" 2>/dev/null)" || agent_info=""
agent_pid="$(print -r -- "$agent_info" | /usr/bin/awk '/^[[:space:]]*pid =/ { print $3; exit }')"
if [[ -z "$agent_pid" || "$agent_pid" == "0" ]]; then
  msg "The LaunchAgent did not remain running." \
      "LaunchAgent nie pozostał uruchomiony."
  msg "Check: launchctl print gui/$UID/$LABEL" \
      "Sprawdź: launchctl print gui/$UID/$LABEL"
  exit 1
fi

msg "Installed and running (PID $agent_pid)." \
    "Zainstalowano i uruchomiono (PID $agent_pid)."
if [[ "$notifications_value" == "1" ]]; then
  msg "Notifications: enabled (${notification_language:-auto})." \
      "Powiadomienia: włączone (${notification_language:-auto})."
else
  msg "Notifications: disabled (silent mode)." \
      "Powiadomienia: wyłączone (tryb cichy)."
fi
msg "Log: $LOG_DIR/guard.log" "Log: $LOG_DIR/guard.log"
