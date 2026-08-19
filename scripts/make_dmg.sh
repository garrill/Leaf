#!/bin/sh
# Builds Leaf in Release configuration and packages it into a DMG under build/.
#
# This produces an unsigned/ad-hoc DMG using whatever signing identity Xcode's Automatic
# signing picks (currently a Development identity, not Developer ID — see ROADMAP.md #5).
# Once a paid Apple Developer account + Developer ID Application certificate exist, this
# script needs a notarization step added after DMG creation:
#   xcrun notarytool submit "$DMG_PATH" --keychain-profile <profile> --wait
#   xcrun stapler staple "$DMG_PATH"
set -eu

cd "$(dirname "$0")/.."

BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_NAME="Leaf"

rm -rf "$DERIVED_DATA"

xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
	-derivedDataPath "$DERIVED_DATA" \
	build

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
	echo "error: built app not found at $APP_PATH" >&2
	exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")

STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING"

echo "Created $DMG_PATH"
