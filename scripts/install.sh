#!/bin/bash
# Install AntiClick as a per-user login agent (no sudo needed) and start it.
#
#   ./scripts/install.sh [anticlick options...]
#   e.g. ./scripts/install.sh                      # hold the current output if it is USB
#        ./scripts/install.sh --match "USB Audio CODEC" --always
#
# Re-running it replaces the installed copy and restarts the agent.
set -euo pipefail

LABEL="io.github.kevinwells22.anticlick.agent"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BIN="$HERE/build/anticlick"
DEST_DIR="$HOME/Library/Application Support/AntiClick"
DEST_BIN="$DEST_DIR/anticlick"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/AntiClick.log"
DOMAIN="gui/$(id -u)"

# -f, not -x: on network shares (SMB) the executable test can fail for a runnable file.
if [ ! -f "$SRC_BIN" ]; then
    echo "anticlick is not built yet: run 'make' first" >&2
    exit 1
fi

# Reject bad options before touching anything (--list parses the same options).
"$SRC_BIN" --list "$@" >/dev/null

if pgrep -x AntiClick >/dev/null; then
    echo "note: the AntiClick menu-bar app is running too. Use one or the other;"
    echo "      quit the app (and turn off its Open at Login) if you prefer this agent."
fi

mkdir -p "$DEST_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop a running copy before replacing it. The binary lives in your home folder,
# not in this project folder, so the agent still works if this volume (here a
# network share) is not mounted at login.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
install -m 755 "$SRC_BIN" "$DEST_BIN"

xml_escape() {
    local s=$1
    s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}
    printf '%s' "$s"
}

# Hardware-hold mode does no real-time work, so it can run as a throttled
# background job. The --silence fallback runs a real-time IOProc: don't throttle.
process_type="Background"
for a in "$@"; do
    case "$a" in
        --silence) process_type="Standard" ;;
        --*) ;;
        -*s*) process_type="Standard" ;;
    esac
done

{
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$DEST_BIN")</string>
EOF
    for a in "$@"; do
        printf '        <string>%s</string>\n' "$(xml_escape "$a")"
    done
    cat <<EOF
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>$process_type</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF
} > "$PLIST"

plutil -lint "$PLIST" >/dev/null
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed AntiClick:"
echo "  binary  $DEST_BIN"
echo "  agent   $PLIST  (starts at every login, restarts if it crashes)"
echo "  log     $LOG"
echo
sleep 1
"$DEST_BIN" --list "$@"
