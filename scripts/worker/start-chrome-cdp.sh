#!/bin/bash
# start-chrome-cdp.sh — Ensure Chrome runs with CDP remote debugging on port 9222
# Called by LaunchAgent on login OR manually after setup
#
# Chrome 146+ requires --user-data-dir pointing to a REAL directory (not a symlink
# to the default profile) for CDP to work. This script:
#   1. Checks if CDP is already active
#   2. If Chrome is running without CDP, restarts it
#   3. Starts Chrome with the correct flags

CDP_PORT=9222
USER_DATA_DIR="$HOME/chrome-cdp-profile"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LOG_TAG="[chrome-cdp]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $*"; }

# If called from LaunchAgent, wait for GUI session to be ready
if [ "${1:-}" = "--wait" ]; then
    log "Waiting for GUI session..."
    sleep 12
fi

# 1. Already active?
if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    log "CDP already active on port $CDP_PORT"
    exit 0
fi

# 2. Chrome running without CDP? Restart it.
if pgrep -xf ".*Google Chrome$" > /dev/null 2>&1 || pgrep -f "Google Chrome.app/Contents/MacOS/Google Chrome" > /dev/null 2>&1; then
    log "Chrome running without CDP, restarting..."
    osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
    sleep 5
    # Force kill if still hanging
    if pgrep -f "Google Chrome" > /dev/null 2>&1; then
        pkill -f "Google Chrome" 2>/dev/null
        sleep 3
    fi
fi

# 3. Verify user-data-dir exists and is a real directory (not a symlink)
if [ -L "$USER_DATA_DIR" ]; then
    log "ERROR: $USER_DATA_DIR is a symlink — CDP will not work. Run setup-chrome-cdp.sh first."
    exit 1
fi
if [ ! -d "$USER_DATA_DIR" ]; then
    log "ERROR: $USER_DATA_DIR does not exist. Run setup-chrome-cdp.sh first."
    exit 1
fi

# 4. Start Chrome with CDP
log "Starting Chrome with CDP on port $CDP_PORT, data-dir=$USER_DATA_DIR"
"$CHROME" \
    --remote-debugging-port=$CDP_PORT \
    --user-data-dir="$USER_DATA_DIR" \
    --no-first-run &

# 5. Wait and verify
sleep 8
if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    log "CDP verified on port $CDP_PORT"
    curl -s "http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null
    exit 0
else
    log "WARNING: CDP not responding after start — check Chrome process"
    ps aux | grep -i "[C]hrome" | head -3
    exit 1
fi
