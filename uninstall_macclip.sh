#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.macclip.agent.plist"
LABEL="com.macclip.agent"
UID_VALUE="$(id -u)"
INSTALL_DIR="$HOME/Library/ApplicationSupport/MacClip"

launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl disable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true

rm -f "$PLIST"
rm -f "$INSTALL_DIR/MacClip"

echo "MacClip stopped and removed."
