#!/bin/bash
# Пакує "MCV Browser.app" у звичайний drag-to-Applications DMG.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="MCV Browser.app"
DMG="MCV-Browser.dmg"
VOLUME_NAME="MCV Browser"
STAGING="$(mktemp -d)"

if [ ! -d "$APP" ]; then
  echo "✕ '$APP' не знайдено — спочатку 'make app'" >&2
  exit 1
fi

trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "✓ $DMG готовий ($(du -sh "$DMG" | cut -f1))"
