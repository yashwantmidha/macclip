#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/ApplicationSupport/MacClip"
BIN="$INSTALL_DIR/MacClip"
PLIST="$HOME/Library/LaunchAgents/com.macclip.agent.plist"
LABEL="com.macclip.agent"
UID_VALUE="$(id -u)"

if [[ ! -f "$ROOT_DIR/Package.swift" ]]; then
  echo "Package.swift not found in: $ROOT_DIR"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

swift build -c release --package-path "$ROOT_DIR"
cp "$ROOT_DIR/.build/release/macclip" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

echo "MacClip installed and running."
echo "Option+V: clipboard history · Option+Shift+R: capture region"
