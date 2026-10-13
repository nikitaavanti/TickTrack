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
cp Support/AboutAnimation.png "$APP/Contents/Resources/AboutAnimation.png"

# Номер сборки = число коммитов: растёт сам, вручную не трогаем. Версия для людей — в Support/Info.plist.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
codesign --force --sign - "$APP"

echo "Готово: $APP (версия $VERSION, сборка $BUILD)"
echo "Запуск: open $APP"
