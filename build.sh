#!/bin/bash
# Builds TermWall.app (with TermWall.saver inside it).
# "./build.sh install" also copies the app to ~/Applications, the screen saver to
# ~/Library/Screen Savers, and launches the app.
set -euo pipefail
cd "$(dirname "$0")"
FLAGS=(-O -swift-version 5)

SAVER=build/TermWall.saver
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp Saver-Info.plist "$SAVER/Contents/Info.plist"
cp wall.html "$SAVER/Contents/Resources/"
swiftc "${FLAGS[@]}" -emit-library -module-name TermWallSaver ${SAVER_FLAGS:-} -o "$SAVER/Contents/MacOS/TermWall" \
  Sources/Saver.swift Sources/Shared.swift -framework ScreenSaver -framework WebKit -framework Cocoa
codesign --force -s - "$SAVER" >/dev/null
echo "Built $SAVER"

APP=build/TermWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp wall.html "$APP/Contents/Resources/"
cp -R "$SAVER" "$APP/Contents/Resources/"
swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/TermWall" Sources/main.swift Sources/Shared.swift \
  -framework Cocoa -framework WebKit -framework SwiftUI -framework IOKit
codesign --force -s - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x TermWall || true
  sleep 0.5
  mkdir -p ~/Applications ~/Library/Screen\ Savers
  rm -rf ~/Applications/TermWall.app ~/Library/Screen\ Savers/TermWall.saver
  cp -R "$APP" ~/Applications/
  cp -R "$SAVER" ~/Library/Screen\ Savers/
  killall legacyScreenSaver 2>/dev/null || true   # so macOS loads the new screen saver
  open ~/Applications/TermWall.app
  echo "Installed TermWall.app to ~/Applications and TermWall.saver to ~/Library/Screen Savers, and launched the app"
fi
