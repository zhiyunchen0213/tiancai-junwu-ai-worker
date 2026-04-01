#!/bin/bash
# setup-chrome-cdp.sh — One-time setup for Chrome CDP remote debugging on Mac mini workers
#
# What this does:
#   1. Quits Chrome
#   2. Creates a REAL ~/chrome-cdp-profile directory (not a symlink)
#   3. Copies the existing Chrome profile (preserving jimeng login state)
#   4. Installs a LaunchAgent for auto-start on login
#   5. Starts Chrome with CDP and verifies
#
# Why: Chrome 146+ requires --user-data-dir to point to a non-default directory
# for CDP (remote debugging port 9222) to work. A symlink to the default dir
# is resolved by Chrome and treated as "default" — CDP is rejected.

set -euo pipefail

CDP_PORT=9222
USER_DATA_DIR="$HOME/chrome-cdp-profile"
CHROME_DEFAULT_DIR="$HOME/Library/Application Support/Google/Chrome"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORKER_CODE_DIR="$HOME/worker-code/scripts/worker"
LAUNCH_AGENT_LABEL="com.worker.chrome-cdp"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

log() { echo "[setup-chrome-cdp] $(date '+%H:%M:%S') $*"; }

# --- Pre-checks ---
if [ ! -d "$CHROME_DEFAULT_DIR" ]; then
    log "ERROR: Chrome default profile not found at $CHROME_DEFAULT_DIR"
    exit 1
fi

if [ ! -f "$CHROME" ]; then
    log "ERROR: Chrome not found at $CHROME"
    exit 1
fi

# --- Step 1: Quit Chrome ---
log "Step 1: Quitting Chrome..."
if pgrep -f "Google Chrome" > /dev/null 2>&1; then
    osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null || true
    sleep 5
    if pgrep -f "Google Chrome" > /dev/null 2>&1; then
        log "Force killing Chrome..."
        pkill -f "Google Chrome" 2>/dev/null || true
        sleep 3
    fi
fi
log "Chrome stopped."

# --- Step 2: Create real directory ---
log "Step 2: Setting up $USER_DATA_DIR..."
if [ -L "$USER_DATA_DIR" ]; then
    log "Removing symlink: $USER_DATA_DIR -> $(readlink "$USER_DATA_DIR")"
    rm "$USER_DATA_DIR"
elif [ -d "$USER_DATA_DIR" ]; then
    # Real directory already exists — check if it has a Default/ profile
    if [ -d "$USER_DATA_DIR/Default" ]; then
        log "Real directory already exists with Default/ profile. Skipping copy."
        SKIP_COPY=1
    else
        log "Real directory exists but no Default/ profile. Will copy."
    fi
fi

# --- Step 3: Copy profile ---
if [ "${SKIP_COPY:-}" != "1" ]; then
    log "Step 3: Copying Chrome profile (this may take a minute)..."
    mkdir -p "$USER_DATA_DIR"

    # Copy Default profile (contains cookies, login state, localStorage)
    rsync -a --exclude='Cache' --exclude='Code Cache' --exclude='Service Worker/CacheStorage' \
        --exclude='GrShaderCache' --exclude='GraphiteDawnCache' --exclude='ShaderCache' \
        --exclude='component_crx_cache' --exclude='BrowserMetrics-spare.pma' \
        "$CHROME_DEFAULT_DIR/Default" "$USER_DATA_DIR/"

    # Copy Local State (required for Chrome to recognize the profile)
    cp "$CHROME_DEFAULT_DIR/Local State" "$USER_DATA_DIR/" 2>/dev/null || true

    # Remove lock files from copied data
    rm -f "$USER_DATA_DIR/SingletonLock" "$USER_DATA_DIR/SingletonSocket" "$USER_DATA_DIR/SingletonCookie"

    PROFILE_SIZE=$(du -sh "$USER_DATA_DIR" 2>/dev/null | cut -f1)
    log "Profile copied. Size: $PROFILE_SIZE"
else
    log "Step 3: Skipped (profile already exists)."
fi

# --- Step 4: Install LaunchAgent ---
log "Step 4: Installing LaunchAgent for auto-start..."
mkdir -p "$HOME/Library/LaunchAgents"

# Unload existing agent if present
launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true

# Determine the start script path
START_SCRIPT="$WORKER_CODE_DIR/start-chrome-cdp.sh"
if [ ! -f "$START_SCRIPT" ]; then
    # Fallback: look in same directory as this script
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    START_SCRIPT="$SCRIPT_DIR/start-chrome-cdp.sh"
fi

if [ ! -f "$START_SCRIPT" ]; then
    log "WARNING: start-chrome-cdp.sh not found, LaunchAgent will use inline command"
    START_SCRIPT=""
fi

if [ -n "$START_SCRIPT" ]; then
    chmod +x "$START_SCRIPT"
    cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${START_SCRIPT}</string>
        <string>--wait</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>/tmp/chrome-cdp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chrome-cdp.log</string>
</dict>
</plist>
PLIST
else
    cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>sleep 12; /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=9222 --user-data-dir=\$HOME/chrome-cdp-profile --no-first-run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>/tmp/chrome-cdp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chrome-cdp.log</string>
</dict>
</plist>
PLIST
fi

launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
log "LaunchAgent installed at $LAUNCH_AGENT_PLIST"

# --- Step 5: Start Chrome with CDP ---
log "Step 5: Starting Chrome with CDP..."
"$CHROME" \
    --remote-debugging-port=$CDP_PORT \
    --user-data-dir="$USER_DATA_DIR" \
    --no-first-run &

sleep 8

# --- Step 6: Verify ---
log "Step 6: Verifying CDP..."
if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    CDP_VERSION=$(curl -s "http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null)
    log "SUCCESS: CDP active on port $CDP_PORT"
    echo "$CDP_VERSION"
else
    log "FAILED: CDP not responding on port $CDP_PORT"
    log "Chrome process:"
    ps aux | grep -i "[C]hrome" | grep -v Helper | head -3
    exit 1
fi

log "Setup complete. Chrome will auto-start with CDP on next login."
