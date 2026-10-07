#!/bin/bash
set -euo pipefail

LABEL="com.mouseless.daemon"

sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist"
sudo rm -f /usr/local/bin/mouseless-daemon
sudo rm -f /var/run/mouseless.sock
sudo rm -f /var/log/mouseless-daemon.log

echo "mouseless-daemon uninstalled"
