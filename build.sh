#!/bin/bash
set -e

echo "Building CodexSwitcher..."
swiftc CodexSwitcher.swift -o CodexSwitcher \
    -framework AppKit \
    -framework UserNotifications \
    -framework ServiceManagement \
    -O

# Update app bundle
mkdir -p CodexSwitcher.app/Contents/MacOS
cp CodexSwitcher CodexSwitcher.app/Contents/MacOS/CodexSwitcher
cp Info.plist CodexSwitcher.app/Contents/Info.plist
mkdir -p CodexSwitcher.app/Contents/Resources
cp AppIcon.icns CodexSwitcher.app/Contents/Resources/AppIcon.icns

echo "Done. Run with: open CodexSwitcher.app"
