#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <github-owner/repository> <version> <build-number>" >&2
  exit 64
fi

REPOSITORY="$1"
VERSION="$2"
BUILD_NUMBER="$3"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
DIST="dist"
FEED_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/appcast.xml"
DOWNLOAD_PREFIX="https://github.com/${REPOSITORY}/releases/download/v${VERSION}/"

swift package resolve
PUBLIC_KEY="$($SPARKLE_BIN/generate_keys --account mcv-browser -p)"

make app VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
  UPDATE_FEED_URL="$FEED_URL" UPDATE_PUBLIC_KEY="$PUBLIC_KEY"

# Never let a stale local archive become the newest appcast item. The durable
# history is the committed appcast and GitHub releases, not an ignored folder.
rm -rf "$DIST"
mkdir -p "$DIST"
if [ -f appcast.xml ]; then cp appcast.xml "$DIST/appcast.xml"; fi
ARCHIVE="MCV-Browser-${VERSION}.zip"
rm -f "$DIST/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "MCV Browser.app" "$DIST/$ARCHIVE"

"$SPARKLE_BIN/generate_appcast" --account mcv-browser \
  --download-url-prefix "$DOWNLOAD_PREFIX" --link "https://github.com/${REPOSITORY}" \
  --maximum-versions 5 "$DIST"

cp "$DIST/appcast.xml" appcast.xml
echo "Built $DIST/$ARCHIVE and signed appcast.xml"
echo "Upload the ZIP to GitHub release v$VERSION, then commit appcast.xml."
