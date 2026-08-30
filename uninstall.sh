#!/bin/zsh
# Uninstall arq-gfn-guard. Do not use sudo.

emulate -LR zsh
setopt err_exit nounset pipe_fail

readonly LABEL="com.local.arq-gfn-guard"
readonly DEST_DIR="$HOME/Library/Application Support/ArqGFNGuard"
readonly DEST_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

message_language="${ARQ_GFN_INSTALL_LANG:-${ARQ_GFN_LANG:-}}"
if [[ -z "$message_language" ]]; then
  message_language="$(/usr/bin/defaults read -g AppleLocale 2>/dev/null)" \
    || message_language="en"
fi

msg() {
  if [[ "$message_language" == pl* ]]; then
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

/bin/launchctl bootout "gui/$UID/$LABEL" 2>/dev/null \
  || /bin/launchctl unload "$DEST_PLIST" 2>/dev/null \
  || true
/bin/rm -f "$DEST_PLIST"
/bin/rm -rf "$DEST_DIR"

msg "Uninstalled. Logs remain in ~/Library/Logs/ArqGFNGuard/. Any active guard pause expires automatically within 10 minutes." \
    "Odinstalowano. Logi pozostają w ~/Library/Logs/ArqGFNGuard/. Aktywna pauza guarda wygaśnie automatycznie w ciągu 10 minut."
