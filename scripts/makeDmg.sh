#!/usr/bin/env bash
# Packages MFinder.app into a distributable DMG with a drag-to-Applications
# shortcut. Run after `./build.sh release` has produced MFinder.app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="MFinder"
APP_BUNDLE="$ROOT/$APP_NAME.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "✗ $APP_BUNDLE not found. Run ./build.sh release first."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"

STAGE="$(mktemp -d -t MFinder-dmg)"
trap 'rm -rf "$STAGE"' EXIT

echo "→ Staging $APP_BUNDLE for v$VERSION"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

VERSIONED="$ROOT/$APP_NAME-v$VERSION.dmg"
LATEST="$ROOT/$APP_NAME.dmg"
rm -f "$VERSIONED" "$LATEST"

echo "→ Building $VERSIONED"
hdiutil create \
    -volname "$APP_NAME v$VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$VERSIONED" >/dev/null

cp "$VERSIONED" "$LATEST"

echo "✓ Built $VERSIONED"
echo "✓ Built $LATEST (alias of the versioned dmg)"
