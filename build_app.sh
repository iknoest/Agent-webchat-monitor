#!/bin/bash
# AgentSignalBar macOS App Bundle Builder Script
set -e

echo "🔨 Building Swift Release Binary..."
swift build -c release

APP_DIR="AgentSignalBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "📦 Creating macOS App Bundle ($APP_DIR)..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp -f .build/release/AgentSignalBar "$MACOS_DIR/AgentSignalBar"

cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentSignalBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.ava.AgentSignalBar</string>
    <key>CFBundleName</key>
    <string>AgentSignalBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ AgentSignalBar.app bundle created successfully!"
echo "💡 You can launch it with: open AgentSignalBar.app"
