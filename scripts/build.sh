#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Linkosaur.app"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"

cd "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CLANG_MODULE_CACHE_PATH"
clang -fobjc-arc -O2 \
    -mmacosx-version-min=13.0 \
    -framework Cocoa \
    "$ROOT/Sources/Linkosaur/main.m" \
    -o "$APP/Contents/MacOS/Linkosaur"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/Linkosaur.icns" "$APP/Contents/Resources/Linkosaur.icns"

# Ad-hoc signing keeps the bundle identity stable for Launch Services.
codesign --force --deep --sign - "$APP"

echo "$APP"
