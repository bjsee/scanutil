#!/bin/bash
# Baut Scanutil.app aus dem Swift Package, mit Info.plist (Kamerahinweis) und lokaler Signatur.
# Aufruf: scripts/bundle.sh [Zielordner]   Standard: build/
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Scanutil.app"

swift build -c release --product Scanutil
BIN="$(swift build -c release --show-bin-path)/Scanutil"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scanutil"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Scanutil</string>
    <key>CFBundleDisplayName</key><string>Scanutil</string>
    <key>CFBundleIdentifier</key><string>de.mulsum1524.scanutil</string>
    <key>CFBundleExecutable</key><string>Scanutil</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key>
    <string>Scanutil nimmt Bilder vom angeschlossenen Scanner (CZUR ET24 Pro) auf. Der Scanner meldet sich als Kamera.</string>
</dict>
</plist>
PLIST

# Lokale (ad-hoc) Signatur, genügt für den eigenen Rechner. Für die Weitergabe wäre eine Developer-ID nötig.
codesign --force --sign - "$APP"
echo "gebaut: $APP"
