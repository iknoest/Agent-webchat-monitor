#!/bin/bash
# AgentSignalBar / AgentBridge macOS App Bundle Builder Script
set -e

echo "🔨 Building Swift Release Binary..."
swift build -c release

APP_DIR="AgentBridge.app"
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

# Maintain backward compatibility link in repository
ln -sfn "$APP_DIR" AgentSignalBar.app

echo "✅ AgentBridge ($APP_DIR) bundle created successfully!"

# Install to /Applications if writable
if [ -w "/Applications" ]; then
    echo "📲 Installing to /Applications/AgentBridge.app..."
    rm -rf "/Applications/AgentBridge.app"
    cp -Rf "$APP_DIR" "/Applications/AgentBridge.app"

    # Clean up obsolete AgentSignalBar.app if present and matches our bundle ID
    if [ -d "/Applications/AgentSignalBar.app" ]; then
        OLD_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "/Applications/AgentSignalBar.app/Contents/Info.plist" 2>/dev/null || true)
        if [ "$OLD_BUNDLE_ID" = "com.ava.AgentSignalBar" ]; then
            echo "🧹 Removing obsolete duplicate /Applications/AgentSignalBar.app..."
            rm -rf "/Applications/AgentSignalBar.app"
        fi
    fi

    # Refresh LaunchServices database
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/AgentBridge.app" 2>/dev/null || true
    echo "✨ Installed to /Applications/AgentBridge.app successfully!"
    echo "💡 You can launch it with: open /Applications/AgentBridge.app"
else
    echo "💡 You can launch it with: open AgentBridge.app"
fi
