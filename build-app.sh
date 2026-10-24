#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
swift build -c release

APP="$ROOT/dist/KeySplash.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
cp "$ROOT/.build/release/KeySplash" "$MACOS/KeySplash"
cp "$ROOT/artifacts/handprint-options.png" "$RESOURCES/handprint-options.png"
ICONSET=$(mktemp -d)
trap 'rm -rf "$ICONSET"' EXIT HUP INT TERM
mkdir "$ICONSET/KeySplash.iconset"
for SIZE in 16 32 64 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ROOT/artwork/keysplash-icon.png" --out "$ICONSET/KeySplash.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ROOT/artwork/keysplash-icon.png" --out "$ICONSET/KeySplash.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET/KeySplash.iconset" -o "$RESOURCES/KeySplash.icns"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KeySplash</string>
    <key>CFBundleIdentifier</key><string>app.keysplash.cleaningmode</string>
    <key>CFBundleName</key><string>KeySplash</string>
    <key>CFBundleIconFile</key><string>KeySplash</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
