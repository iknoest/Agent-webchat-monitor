#!/bin/bash
# AgentSignalBar / AgentBridge macOS App Bundle Builder Script
set -e

echo "🔨 Building Swift Release Binary..."
swift build -c release

APP_DIR="AgentSignalBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "📦 Creating macOS App Bundle ($APP_DIR)..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR/icons"

cp -f .build/release/AgentSignalBar "$MACOS_DIR/AgentSignalBar"
if [ -f "Resources/AppIcon.icns" ]; then
    cp -f "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -d "agent-white-icon" ]; then
    cp -Rf agent-white-icon/* "$RESOURCES_DIR/icons/" 2>/dev/null || true
fi

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
    <string>AgentBridge</string>
    <key>CFBundleDisplayName</key>
    <string>AgentBridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
echo "✅ AgentBridge ($APP_DIR) bundle created successfully!"
echo "💡 You can launch it with: open AgentSignalBar.app"
