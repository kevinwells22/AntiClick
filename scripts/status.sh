#!/bin/bash
# Show whether AntiClick (menu-bar app or command-line agent) is running, what
# it holds, and what it costs.
set -uo pipefail

LABEL="io.github.kevinwells22.anticlick.agent"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/Library/Application Support/AntiClick/anticlick"
LOG="$HOME/Library/Logs/AntiClick.log"
DOMAIN="gui/$(id -u)"
pids=()

app_pid=$(pgrep -x AntiClick | head -1)
if [ -n "$app_pid" ]; then
    echo "app:     AntiClick.app is running (pid $app_pid)"
    pids+=("$app_pid")
else
    echo "app:     AntiClick.app is not running"
fi

if info=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null); then
    state=$(awk -F' = ' '/^\tstate = /{print $2; exit}' <<<"$info")
    pid=$(awk -F' = ' '/^\tpid = /{print $2; exit}' <<<"$info")
    echo "agent:   $LABEL is loaded, state: ${state:-unknown}${pid:+, pid $pid}"
    [ -n "${pid:-}" ] && pids+=("$pid")
else
    echo "agent:   command-line agent not installed"
fi

if [ ${#pids[@]} -gt 0 ] && [ -f "$HERE/tools/pidstat.rb" ]; then
    echo "measuring for 10 s..."
    /usr/bin/ruby "$HERE/tools/pidstat.rb" --seconds 10 "${pids[@]}" | sed 's/^/         /'
fi
echo
if [ -f "$HERE/build/anticlick" ]; then
    "$HERE/build/anticlick" --list
elif [ -f "$BIN" ]; then
    "$BIN" --list
fi
if [ -n "$app_pid" ]; then
    echo
    echo "recent app activity (unified log):"
    /usr/bin/log show --last 1d --style compact --predicate 'subsystem == "io.github.kevinwells22.anticlick"' 2>/dev/null \
        | grep -v '^Timestamp' | tail -n 6 | sed -E 's/^([0-9-]+ [0-9:]+)\.[0-9]+ .*\] /  \1  /'
elif [ -f "$LOG" ]; then
    echo
    echo "last agent log lines ($LOG):"
    tail -n 6 "$LOG" | sed 's/^/  /'
fi
