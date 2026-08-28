#!/bin/sh
# Builds Leaf in Release configuration, code-signs it with the Developer ID Application
# identity, packages it into a DMG under build/, then notarizes and staples it.
#
# Requires: a "Developer ID Application" certificate in this Mac's keychain (the identity
# string below must match one from `security find-identity -v -p codesigning`), and a
# notarytool keychain profile named "leaf-notary" (`xcrun notarytool store-credentials
# leaf-notary --apple-id ... --team-id VL4Z3W8N24 --password <app-specific password>`).
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

# Shrink the shipped bundle before signing (both steps invalidate signatures — the
# re-sign block below covers them). `xcodebuild build` (vs archive/install) never runs
# Xcode's install-time strip, so the executable still carries its full ~3.4 MB symbol
# table; -rSTx drops debug + local symbols while keeping dynamically-referenced ones
# (safe for the app's @objc/AppKit interop). The dwarf-with-dsym Leaf.app.dSYM produced
# by the build is untouched, so crash symbolication still works.
strip -rSTx "$APP_PATH/Contents/MacOS/$APP_NAME"

# Sparkle ships 36 .lproj translations of its own updater UI; Leaf itself is English-only,
# so drop all but en/Base. Restore by deleting this line if Leaf is ever localized.
find "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Resources" -maxdepth 1 \
	-name '*.lproj' ! -name 'en.lproj' ! -name 'Base.lproj' -exec rm -rf {} +

# Sparkle's SPM binary artifact ships every Mach-O as fat x86_64+arm64. Leaf's Release
# config is pinned to ARCHS = arm64, so the x86_64 slices are dead weight (~1.2 MB) —
# thin them to match. Re-signed by the block below.
SPARKLE_VER="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
for macho in \
	"$SPARKLE_VER/Sparkle" \
	"$SPARKLE_VER/Autoupdate" \
	"$SPARKLE_VER/Updater.app/Contents/MacOS/Updater" \
	"$SPARKLE_VER/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
	"$SPARKLE_VER/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
	if lipo -archs "$macho" 2>/dev/null | grep -qw x86_64; then
		lipo "$macho" -thin arm64 -output "$macho"
	fi
done

# Xcode's Automatic-signing "Embed Frameworks" phase does not reliably re-sign Sparkle's
# prebuilt nested helper tools (they ship ad-hoc signed from the SPM binary artifact), and
# separately bakes com.apple.security.get-task-allow into the main executable even for a
# plain `xcodebuild build` — both fail notarization. Re-sign everything explicitly here,
# innermost first, with the real Developer ID identity, hardened runtime, and a secure
# timestamp; the outer app is re-signed last with no entitlements (drops get-task-allow).
IDENTITY="Developer ID Application: Jonny Garrill (VL4Z3W8N24)"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$SPARKLE_FW"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
	"$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" --keychain-profile "leaf-notary" --wait
xcrun stapler staple "$DMG_PATH"

rm -rf "$STAGING"

echo "Created $DMG_PATH"
