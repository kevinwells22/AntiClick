#!/bin/bash
# Stop AntiClick and remove the login agent and installed binary.
set -uo pipefail

LABEL="io.github.kevinwells22.anticlick.agent"
DEST_DIR="$HOME/Library/Application Support/AntiClick"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/AntiClick.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL" || echo "$LABEL was not running"
rm -f "$PLIST" && echo "removed $PLIST"
rm -rf "$DEST_DIR" && echo "removed $DEST_DIR"
echo "kept the log at $LOG (delete it if you like)"
