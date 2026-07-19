#!/bin/sh

# Archive and export the Dirnex app as a signed Developer ID build (PLAN.md §M7).
#
# Unlike the reference pipeline this was ported from (a pure-SwiftPM app that hand-assembled its
# bundle from `swift build`), Dirnex is an Xcode project: SwiftTerm and Sparkle are embedded
# frameworks/XPC services, and only `xcodebuild archive` + `-exportArchive` sign that nested code
# correctly. The archive is signed with the Developer ID identity (so the embedded frameworks are
# signed in place), and the export re-signs the whole bundle for distribution using
# Packaging/ExportOptions.plist. The hardened runtime is already on in the target build settings.
#
# Env:
#   SIGN_IDENTITY   codesign identity (default "-" ad-hoc; CI passes the Developer ID name).
#   TEAM_ID         Apple Developer team id (default A9N92VGA2M).
#   VERSION         marketing version (defaults to the VERSION file).
#   BUILD_NUMBER    CFBundleVersion (defaults to VERSION).
#   CONFIGURATION   xcodebuild configuration (default Release).
#
# Prints the path to the exported .app on success.

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Dirnex"
SCHEME="Dirnex"
CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-A9N92VGA2M}"
DIST_DIR="$ROOT_DIR/dist"
DERIVED_DIR="$ROOT_DIR/build/release-dd"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$DIST_DIR/export"
EXPORT_OPTIONS="$ROOT_DIR/Packaging/ExportOptions.plist"
VERSION_FILE="$ROOT_DIR/VERSION"

cd "$ROOT_DIR"

if [ -z "${VERSION:-}" ] && [ -f "$VERSION_FILE" ]; then
    VERSION=$(sed -n '1p' "$VERSION_FILE" | tr -d '[:space:]')
fi

if [ -z "${BUILD_NUMBER:-}" ] && [ -n "${VERSION:-}" ]; then
    BUILD_NUMBER="$VERSION"
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$DIST_DIR"

# Only override the version fields when they are actually set, so a bare local run still archives
# with whatever the project carries.
set -- \
    -project "$ROOT_DIR/Dirnex.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

if [ -n "${VERSION:-}" ]; then
    set -- "$@" "MARKETING_VERSION=$VERSION"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    set -- "$@" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
fi

xcodebuild archive "$@"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
codesign --verify --strict "$APP_PATH"

echo "$APP_PATH"
