#!/bin/bash
set -euo pipefail

PRODUCT="BitSwitch"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$PRODUCT.app"
CONTENTS="$APP_BUNDLE/Contents"
SOURCES="Sources/*.swift"

case "${1:-build}" in
    build)
        echo "Building $PRODUCT..."
        rm -rf "$BUILD_DIR"
        mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

        swiftc \
            -o "$CONTENTS/MacOS/$PRODUCT" \
            -target arm64-apple-macosx13.0 \
            -framework CoreAudio \
            -framework AppKit \
            -framework SwiftUI \
            -parse-as-library \
            -swift-version 5 \
            $SOURCES

        cp Resources/Info.plist "$CONTENTS/"

        echo "Built $APP_BUNDLE"
        echo ""
        echo "Run:      open $APP_BUNDLE"
        echo "Install:  $0 install"
        ;;

    install)
        if [ ! -d "$APP_BUNDLE" ]; then
            echo "No build found. Run '$0 build' first."
            exit 1
        fi

        echo "Installing $PRODUCT..."

        # Stop existing instance
        launchctl unload ~/Library/LaunchAgents/com.altinfinity.bitswitch.plist 2>/dev/null || true
        pkill -f "$PRODUCT.app" 2>/dev/null || true
        sleep 1

        # Copy app
        cp -r "$APP_BUNDLE" /Applications/$PRODUCT.app
        echo "Copied to /Applications/$PRODUCT.app"

        # Install LaunchAgent
        mkdir -p ~/Library/LaunchAgents
        cat > ~/Library/LaunchAgents/com.altinfinity.bitswitch.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.altinfinity.bitswitch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/BitSwitch.app/Contents/MacOS/BitSwitch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST

        launchctl load ~/Library/LaunchAgents/com.altinfinity.bitswitch.plist
        echo "LaunchAgent installed — BitSwitch will start on login."
        echo ""
        echo "BitSwitch is now running."
        ;;

    uninstall)
        echo "Uninstalling $PRODUCT..."
        launchctl unload ~/Library/LaunchAgents/com.altinfinity.bitswitch.plist 2>/dev/null || true
        pkill -f "$PRODUCT.app" 2>/dev/null || true
        rm -f ~/Library/LaunchAgents/com.altinfinity.bitswitch.plist
        rm -rf /Applications/$PRODUCT.app
        rm -rf ~/Library/Application\ Support/BitSwitch
        echo "Uninstalled."
        ;;

    *)
        echo "Usage: $0 [build|install|uninstall]"
        exit 1
        ;;
esac
