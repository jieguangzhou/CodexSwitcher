#!/bin/bash
set -e

echo "Building CodexSwitcher..."
swiftc CodexSwitcher.swift -o CodexSwitcher \
    -framework AppKit \
    -framework UserNotifications \
    -framework ServiceManagement \
    -O

# Update app bundle
APP="CodexSwitcher.app/Contents/MacOS"
mkdir -p "$APP"
cp CodexSwitcher "$APP/CodexSwitcher"

echo "Done. Run with: open CodexSwitcher.app"
