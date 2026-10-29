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
    <key>CFBundleShortVersionString</key><string>1.2.6</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
SIGNING_IDENTITY=${KEYSPLASH_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $2; exit }')}
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
printf 'Built %s\n' "$APP"
