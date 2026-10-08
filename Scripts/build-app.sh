#!/bin/bash
set -euo pipefail
LUMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LUMO_ROOT"
swift build --configuration release
LUMO_BIN="$(swift build --configuration release --show-bin-path)"
LUMO_APP="$LUMO_ROOT/dist/Lumo.app"
mkdir -p "$LUMO_APP/Contents/MacOS" "$LUMO_APP/Contents/Resources"
cp "$LUMO_BIN/Lumo" "$LUMO_APP/Contents/MacOS/Lumo"
cp "$LUMO_ROOT/Scripts/Info.plist" "$LUMO_APP/Contents/Info.plist"
LUMO_BUNDLE="$(find "$LUMO_BIN" -maxdepth 1 -type d -name '*LumoCore*.bundle' -print -quit)"
if [ -z "$LUMO_BUNDLE" ]; then
    echo "Missing LumoCore resource bundle" >&2
    exit 1
fi
ditto "$LUMO_BUNDLE" "$LUMO_APP/Contents/Resources/$(basename "$LUMO_BUNDLE")"
swift "$LUMO_ROOT/Scripts/MakeIcon.swift" "$LUMO_ROOT/.build/Lumo.iconset"
iconutil -c icns "$LUMO_ROOT/.build/Lumo.iconset" -o "$LUMO_APP/Contents/Resources/Lumo.icns"
codesign --force --deep --sign - "$LUMO_APP"
echo "$LUMO_APP"
