#!/bin/bash
# Собирает build/TickTrack.app без Xcode: релизная сборка SwiftPM + Info.plist + ad-hoc подпись.
# Использование: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/TickTrack.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TickTrack" "$APP/Contents/MacOS/TickTrack"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Готово: $APP"
echo "Запуск: open $APP"
