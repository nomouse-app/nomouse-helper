#!/bin/bash
# Build the helper from this source and run it as a root LaunchDaemon.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.mouseless.daemon"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
INSTALL_PATH="/usr/local/bin/mouseless-daemon"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/mouseless-daemon"

sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo install -m 755 -o root -g wheel "$BIN" "$INSTALL_PATH"
sudo install -m 644 -o root -g wheel "$LABEL.plist" "$PLIST_PATH"
sudo launchctl bootstrap system "$PLIST_PATH"

echo "mouseless-daemon installed and started"
