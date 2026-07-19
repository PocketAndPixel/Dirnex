#!/bin/sh

# Package the exported Dirnex.app into a compressed DMG with the usual drag-to-Applications
# layout (PLAN.md §M7). Ported verbatim from the reference pipeline; only the app location differs
# (Xcode's -exportArchive drops the bundle in dist/export/).

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Dirnex"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/export/$APP_NAME.app}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/$APP_NAME.dmg}"
STAGING_DIR="$ROOT_DIR/dist/dmg-root"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle is missing. Run scripts/build_app.sh first." >&2
    exit 1
fi

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "$DMG_PATH"
