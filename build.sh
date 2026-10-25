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

# Localization markers: the bundle declares ko (default) + en/ja/zh-Hans so
# AppKit / SwiftUI load their framework strings (File/Edit/Window/Help, About,
# Quit, Close, Enter Full Screen, …) in whichever of those the user picks.
# MFinder's own UI is localized at runtime by LocalizationService; these empty
# .lproj dirs just let AppKit's own framework strings follow AppleLanguages
# (set by the in-app language picker on relaunch). ko stays first/default.
for lang in ko en ja zh-Hans; do
    mkdir -p "$APP_BUNDLE/Contents/Resources/$lang.lproj"
done

# PkgInfo
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Codesign. Prefer the stable "MFinder Dev" self-signed identity: TCC keys
# folder-access grants (바탕화면/문서/다운로드 허용) to bundle-id + signing
# cert, so a stable cert means users approve ONCE per Mac and updates keep
# the grant. Ad-hoc signatures change every build → every update re-prompts.
# Fall back to ad-hoc when the identity isn't in the keychain.
SIGN_IDENTITY="MFinder Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "→ Signing with identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1 \
        || { echo "⚠ $SIGN_IDENTITY signing failed — falling back to ad-hoc"; \
             codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true; }
else
    echo "⚠ '$SIGN_IDENTITY' identity not found — ad-hoc signing (TCC grants reset on every update)"
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

# Bust macOS icon caches so Finder/Dock pick up the new icon immediately.
touch "$APP_BUNDLE"

echo "✓ Built $APP_BUNDLE"
echo "  Run with:  open '$APP_BUNDLE'"
