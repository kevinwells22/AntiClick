#!/bin/bash
# Measure every implementation the same way: start it against the current
# default output device, let it settle, then sample CPU, wakeups and memory
# with tools/pidstat.rb. Also samples coreaudiod, which does the real work of
# keeping a device running.
#
#   make && make experiments && ./experiments/bench.sh [seconds]
#
# Note: the menu-bar variant briefly shows an icon in the menu bar.
set -uo pipefail
cd "$(dirname "$0")/.."
WIN=${1:-30}
CAD=$(pgrep -x coreaudiod)
DEV=$(./build/anticlick --list --any-transport | awk '/default output/ {sub(/^[* ] +[0-9]+ +/, ""); print; exit}')
echo "device: ${DEV:-unknown}   window: ${WIN}s   $(date '+%Y-%m-%d %H:%M')"
echo

measure() {
    local label=$1; shift
    "$@" >/dev/null 2>&1 &
    local pid=$!
    sleep 4
    if ! kill -0 "$pid" 2>/dev/null; then echo "$label: exited early"; return; fi
    local threads=$(( $(ps -M -p "$pid" | wc -l) - 1 ))
    local out
    out=$(/usr/bin/ruby tools/pidstat.rb --seconds "$WIN" "$pid" "$CAD")
    kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '%-34s threads=%-3s %s\n' "$label" "$threads" "$(sed -n 1p <<<"$out" | sed 's/^[0-9]* *[^ ]* *//')"
    printf '%-34s %s\n' "   coreaudiod meanwhile" "$(sed -n 2p <<<"$out" | sed 's/^[0-9]* *[^ ]* *//; s/wakeups=.*footprint=n\/a *//')"
    sleep 3
}

measure "nothing (baseline)"                 sleep $((WIN + 10))
measure "C agent, hardware hold (default)"   ./build/anticlick --any-transport
measure "C agent, --silence IOProc"          ./build/anticlick --any-transport --silence
measure "Ruby/Fiddle prototype (hold)"       /usr/bin/ruby tools/ca-probe.rb hold --buffer 4096
measure "Swift AVAudioEngine (silence)"      ./experiments/build/avengine
measure "Swift AppKit menu-bar app (hold)"   ./experiments/build/menubar
measure "afplay of a silent file (loop)"     /usr/bin/afplay experiments/build/silence-60s.aiff
