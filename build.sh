#!/usr/bin/env bash
# Builds MFinder as a proper macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="MFinder"
CONFIG="${1:-release}"   # debug | release

echo "→ Building Swift package ($CONFIG)…"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "✗ binary not found at $BIN"
    exit 1
fi

APP_BUNDLE="$ROOT/$APP_NAME.app"
echo "→ Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# App icon
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Korean localization marker: the bundle declares only `ko`, so AppKit /
# SwiftUI load their framework strings (File/Edit/Window/Help, About, Quit,
# Close, Enter Full Screen, …) in Korean regardless of system language,
# matching the app's Korean-only UI.
mkdir -p "$APP_BUNDLE/Contents/Resources/ko.lproj"

# PkgInfo
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc codesign so Gatekeeper / TCC dialogs work on the local machine.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

# Bust macOS icon caches so Finder/Dock pick up the new icon immediately.
touch "$APP_BUNDLE"

echo "✓ Built $APP_BUNDLE"
echo "  Run with:  open '$APP_BUNDLE'"
