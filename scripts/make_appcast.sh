#!/bin/sh

# Emit a one-item Sparkle appcast for the freshly built DMG (PLAN.md §M7). The enclosure carries the
# EdDSA signature that the app's committed SUPublicEDKey verifies, so only a build signed with our
# private key can ever be offered as an update.
#
# Ported from the reference pipeline, with one change: Sparkle's `sign_update` tool ships inside the
# SwiftPM artifact bundle, and an Xcode build unpacks that under the derived-data SourcePackages
# tree rather than a top-level .build/. So the search widened to the release derived-data dir, and
# SPARKLE_SIGN_UPDATE can point straight at a local Sparkle download's bin/sign_update.
#
# Env: DMG_PATH, VERSION/SHORT_VERSION, BUILD_NUMBER, DOWNLOAD_URL, SPARKLE_PRIVATE_KEY_FILE.

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Dirnex"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/$APP_NAME.dmg}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/dist/appcast.xml}"
APPCAST_TITLE="${APPCAST_TITLE:-$APP_NAME}"
APPCAST_LINK="${APPCAST_LINK:-https://github.com/${GITHUB_REPOSITORY:-olegasd123/Dirnex}}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"
VERSION_FILE="$ROOT_DIR/VERSION"
if [ -z "${VERSION:-}" ] && [ -f "$VERSION_FILE" ]; then
    VERSION=$(sed -n '1p' "$VERSION_FILE" | tr -d '[:space:]')
fi
SHORT_VERSION="${SHORT_VERSION:-${VERSION:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-${VERSION:-}}"
DOWNLOAD_URL="${DOWNLOAD_URL:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG is missing: $DMG_PATH" >&2
    exit 1
fi

if [ -z "$SHORT_VERSION" ]; then
    echo "Set VERSION or SHORT_VERSION." >&2
    exit 1
fi

if [ -z "$BUILD_NUMBER" ]; then
    echo "Set BUILD_NUMBER." >&2
    exit 1
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Set DOWNLOAD_URL." >&2
    exit 1
fi

if [ -z "$SPARKLE_PRIVATE_KEY_FILE" ] || [ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    echo "Set SPARKLE_PRIVATE_KEY_FILE to the Sparkle private key file." >&2
    exit 1
fi

if [ -z "$SPARKLE_SIGN_UPDATE" ]; then
    SPARKLE_SIGN_UPDATE=$(find "$ROOT_DIR/build" -name sign_update -type f 2> /dev/null | head -n 1)
fi

if [ -z "$SPARKLE_SIGN_UPDATE" ] || [ ! -x "$SPARKLE_SIGN_UPDATE" ]; then
    echo "Sparkle sign_update tool was not found. Build the app first, or set SPARKLE_SIGN_UPDATE." >&2
    exit 1
fi

xml_escape() {
    printf '%s' "$1" \
        | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g'
}

SIGNATURE=$("$SPARKLE_SIGN_UPDATE" "$DMG_PATH" -f "$SPARKLE_PRIVATE_KEY_FILE")
PUB_DATE=$(LC_ALL=C TZ=GMT date "+%a, %d %b %Y %H:%M:%S %z")
ESCAPED_TITLE=$(xml_escape "$APPCAST_TITLE")
ESCAPED_LINK=$(xml_escape "$APPCAST_LINK")
ESCAPED_DOWNLOAD_URL=$(xml_escape "$DOWNLOAD_URL")
ESCAPED_SHORT_VERSION=$(xml_escape "$SHORT_VERSION")
ESCAPED_BUILD_NUMBER=$(xml_escape "$BUILD_NUMBER")
ESCAPED_MINIMUM_SYSTEM_VERSION=$(xml_escape "$MINIMUM_SYSTEM_VERSION")

mkdir -p "$(dirname "$APPCAST_PATH")"

cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>$ESCAPED_TITLE</title>
        <link>$ESCAPED_LINK</link>
        <description>$ESCAPED_TITLE app updates</description>
        <language>en</language>
        <item>
            <title>Version $ESCAPED_SHORT_VERSION</title>
            <link>$ESCAPED_LINK</link>
            <sparkle:version>$ESCAPED_BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$ESCAPED_SHORT_VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$ESCAPED_MINIMUM_SYSTEM_VERSION</sparkle:minimumSystemVersion>
            <pubDate>$PUB_DATE</pubDate>
            <enclosure url="$ESCAPED_DOWNLOAD_URL"
                       $SIGNATURE
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF

echo "$APPCAST_PATH"
