#!/usr/bin/env bash
# Evrensel (arm64 + x86_64) "Tazele.app" paketini build/ altına üretir.
# Kullanım: scripts/build-app.sh [--install]   (--install: ~/Applications'a kopyalar)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tazele.app"
VERSION="0.1.0"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tazele"


rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tazele"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tazele</string>
    <key>CFBundleDisplayName</key><string>Tazele</string>
    <key>CFBundleIdentifier</key><string>com.yigitbuyukeren.tazele</string>
    <key>CFBundleExecutable</key><string>Tazele</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Yiğit Eren Büyükeren</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Hazır: $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Tazele.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Kuruldu: ~/Applications/Tazele.app"
fi
