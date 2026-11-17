#!/bin/bash
# Builds TermWall.app. Run "./build.sh install" to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/TermWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp wall.html "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/TermWall" Sources/main.swift \
  -framework Cocoa -framework WebKit -framework SwiftUI -framework IOKit
codesign --force -s - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "install" ]]; then
  pkill -x TermWall || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/TermWall.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/TermWall.app
  echo "Installed to ~/Applications/TermWall.app and launched"
fi
