#!/bin/sh

# Emit the Sparkle appcast for the freshly built DMG (PLAN.md §M7). The enclosure carries the EdDSA
# signature that the app's committed SUPublicEDKey verifies, so only a build signed with our private
# key can ever be offered as an update.
#
# Two channels, one appcast (PLAN.md §M7 "Beta + stable update channels"). Dirnex serves a single
# feed that holds at most two items — the latest stable and the latest beta. A beta item is tagged
# `<sparkle:channel>beta</sparkle:channel>`; a stable item is untagged (Sparkle's default channel,
# which every install sees). This script writes the item for the CURRENT release's CHANNEL and,
# given the feed's existing appcast, preserves the item for the OTHER channel, so the merged feed
# always carries both. Sparkle ranks candidates by <sparkle:version> (the build number), so a newer
# stable outranks a running beta and the tester graduates automatically — the whole reason for one
# feed rather than two.
#
# Sparkle's `sign_update` tool ships inside the SwiftPM artifact bundle, which an Xcode build unpacks
# under the derived-data SourcePackages tree rather than a top-level .build/. So the search widened
# to the release derived-data dir, and SPARKLE_SIGN_UPDATE can point straight at a local Sparkle
# download's bin/sign_update.
#
# Env: DMG_PATH, VERSION/SHORT_VERSION, BUILD_NUMBER, DOWNLOAD_URL, SPARKLE_PRIVATE_KEY_FILE,
#      CHANNEL (stable|beta, default stable), EXISTING_APPCAST (optional path to the current feed).

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Dirnex"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/$APP_NAME.dmg}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/dist/appcast.xml}"
APPCAST_TITLE="${APPCAST_TITLE:-$APP_NAME}"
APPCAST_LINK="${APPCAST_LINK:-https://github.com/${GITHUB_REPOSITORY:-olegasd123/Dirnex}}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"
CHANNEL="${CHANNEL:-stable}"
EXISTING_APPCAST="${EXISTING_APPCAST:-}"
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

case "$CHANNEL" in
    stable | beta) ;;
    *)
        echo "CHANNEL must be 'stable' or 'beta' (got '$CHANNEL')." >&2
        exit 1
        ;;
esac

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

# Print the <item> for this build. A beta build carries the channel tag; a stable build is untagged
# so every install (opted in or not) can see it.
emit_item() {
    printf '        <item>\n'
    printf '            <title>Version %s</title>\n' "$ESCAPED_SHORT_VERSION"
    printf '            <link>%s</link>\n' "$ESCAPED_LINK"
    if [ "$CHANNEL" = "beta" ]; then
        printf '            <sparkle:channel>beta</sparkle:channel>\n'
    fi
    printf '            <sparkle:version>%s</sparkle:version>\n' "$ESCAPED_BUILD_NUMBER"
    printf '            <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$ESCAPED_SHORT_VERSION"
    printf '            <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$ESCAPED_MINIMUM_SYSTEM_VERSION"
    printf '            <pubDate>%s</pubDate>\n' "$PUB_DATE"
    printf '            <enclosure url="%s"\n' "$ESCAPED_DOWNLOAD_URL"
    printf '                       %s\n' "$SIGNATURE"
    printf '                       type="application/octet-stream" />\n'
    printf '        </item>\n'
}

# The item(s) from the current feed that belong to the OTHER channel, printed verbatim so their own
# signed enclosure is preserved. An item counts as "beta" iff its block carries a <sparkle:channel>
# tag (only beta items are tagged); everything else is stable. This replaces the current channel's
# item wholesale and keeps the other, so the merged feed holds exactly the latest of each. Relies on
# <item>/</item> sitting on their own lines — which this very script guarantees for the feed it wrote.
OTHER_ITEMS=""
if [ -n "$EXISTING_APPCAST" ] && [ -s "$EXISTING_APPCAST" ]; then
    OTHER_ITEMS=$(awk -v cur="$CHANNEL" '
        /<item>/ { inItem = 1; block = ""; hasChannel = 0 }
        inItem { block = block $0 "\n" }
        inItem && /<sparkle:channel>/ { hasChannel = 1 }
        /<\/item>/ {
            inItem = 0
            itemChannel = hasChannel ? "beta" : "stable"
            if (itemChannel != cur) printf "%s", block
        }
    ' "$EXISTING_APPCAST")
fi

mkdir -p "$(dirname "$APPCAST_PATH")"

{
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
    printf '    <channel>\n'
    printf '        <title>%s</title>\n' "$ESCAPED_TITLE"
    printf '        <link>%s</link>\n' "$ESCAPED_LINK"
    printf '        <description>%s app updates</description>\n' "$ESCAPED_TITLE"
    printf '        <language>en</language>\n'
    if [ -n "$OTHER_ITEMS" ]; then
        printf '%s\n' "$OTHER_ITEMS"
    fi
    emit_item
    printf '    </channel>\n'
    printf '</rss>\n'
} > "$APPCAST_PATH"

echo "$APPCAST_PATH"
