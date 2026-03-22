#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR"
XCODEPROJ="$PROJECT_DIR/checkvist focus.xcodeproj"
SCHEME="checkvist focus"
APP_NAME="checkvist focus.app"
VOL_NAME="checkvist focus"

VERSION="${1:-}"
if [[ -n "$VERSION" ]]; then
  DMG_BASENAME="checkvist-focus-v${VERSION}"
else
  DMG_BASENAME="checkvist-focus-$(date +%Y%m%d-%H%M%S)"
fi

BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DIR="/tmp/checkvist-focus-derived-release"
STAGE_DIR="$BUILD_DIR/dmg-stage"
RW_DMG="$BUILD_DIR/${DMG_BASENAME}-rw.dmg"
FINAL_DMG="$BUILD_DIR/${DMG_BASENAME}.dmg"

rm -rf "$DERIVED_DIR" "$STAGE_DIR" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$BUILD_DIR" "$STAGE_DIR"

xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  -quiet build

APP_PATH="$DERIVED_DIR/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded but app bundle not found: $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -size 64m \
  -fs HFS+ \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -format UDRW \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$DEVICE" || -z "$MOUNT_POINT" ]]; then
  echo "Failed to attach DMG for customization" >&2
  exit 1
fi

APPLESCRIPT_APP_NAME="$APP_NAME"
APPLESCRIPT_VOL_NAME="$VOL_NAME"
osascript >/dev/null <<OSA
tell application "Finder"
  tell disk "$APPLESCRIPT_VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {180, 180, 780, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set position of item "Applications" of container window to {140, 160}
    set position of item "$APPLESCRIPT_APP_NAME" of container window to {420, 160}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA

sync
hdiutil detach "$DEVICE" -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE_DIR"

echo "Created DMG: $FINAL_DMG"
