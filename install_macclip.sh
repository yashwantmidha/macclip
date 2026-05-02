#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT_DIR/macclip.swift"
INSTALL_DIR="$HOME/Library/ApplicationSupport/MacClip"
BIN="$INSTALL_DIR/MacClip"
PLIST="$HOME/Library/LaunchAgents/com.macclip.agent.plist"
LABEL="com.macclip.agent"
UID_VALUE="$(id -u)"
MODULE_CACHE="$(mktemp -d /tmp/macclip-swift-cache.XXXXXX)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

cleanup() {
  rm -rf "$MODULE_CACHE"
}
trap cleanup EXIT

if [[ ! -f "$SRC" ]]; then
  echo "Source file not found: $SRC"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

SWIFTC_ARGS=(-module-cache-path "$MODULE_CACHE" "$SRC" -o "$BIN")
if [[ -n "$SDK_PATH" ]]; then
  SWIFTC_ARGS=(-sdk "$SDK_PATH" "${SWIFTC_ARGS[@]}")
fi
swiftc "${SWIFTC_ARGS[@]}"

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
echo "Use Option+V to open clipboard history."
