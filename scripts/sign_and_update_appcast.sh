#!/bin/sh
# Step 5 of the release flow: sign a built DMG for Sparkle and fold the result into the
# repo's appcast.xml. Run this after ./scripts/make_dmg.sh (and, once the paid Apple
# Developer account is active, after notarizing the DMG — see ROADMAP.md #5).
#
# Usage: ./scripts/sign_and_update_appcast.sh [path/to/Leaf-X.Y.Z.dmg]
# With no argument, picks the newest .dmg in build/.
#
# Needs the EdDSA private key generated earlier (`generate_keys`) to still be in this
# user's Keychain — that's what actually signs the update.
set -eu

cd "$(dirname "$0")/.."

DMG_PATH="${1:-}"
if [ -z "$DMG_PATH" ]; then
	DMG_PATH=$(ls -t build/*.dmg 2>/dev/null | head -1)
fi
if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
	echo "error: no DMG found. Run ./scripts/make_dmg.sh first, or pass a path." >&2
	exit 1
fi

VERSION=$(basename "$DMG_PATH" .dmg | sed 's/^Leaf-//')
if [ -z "$VERSION" ]; then
	echo "error: couldn't parse a version out of $DMG_PATH (expected Leaf-X.Y.Z.dmg)" >&2
	exit 1
fi

GENERATE_APPCAST=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
	-path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -print -quit 2>/dev/null || true)
if [ -z "$GENERATE_APPCAST" ]; then
	echo "error: couldn't find Sparkle's generate_appcast under DerivedData." >&2
	echo "Build the project at least once first so SPM resolves the Sparkle package artifact." >&2
	exit 1
fi

STAGING="build/appcast-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG_PATH" "$STAGING/"

# Pull this version's notes out of CHANGELOG.md (the section under "## [<version>]") so
# generate_appcast can embed them as this item's release notes.
NOTES_FILE="$STAGING/Leaf-$VERSION.md"
awk -v ver="[$VERSION]" '
	/^## \[/ { if (found) exit; if (index($0, ver)) { found=1; next } }
	found { print }
' CHANGELOG.md > "$NOTES_FILE"
if [ ! -s "$NOTES_FILE" ]; then
	echo "warning: no CHANGELOG.md section found for [$VERSION] — item will ship with no release notes" >&2
	rm -f "$NOTES_FILE"
fi

# generate_appcast merges into an existing appcast.xml if one is already present in the
# target directory, so seed it with the repo's current feed before running.
cp appcast.xml "$STAGING/appcast.xml"

# Without this, generate_appcast guesses the enclosure URL from appcast.xml's own <link>
# (the raw.githubusercontent.com feed URL) — wrong, since the DMG itself is hosted as a
# GitHub Release asset, not alongside the feed file. Point it at the release tag this DMG
# will actually be attached to instead.
"$GENERATE_APPCAST" --embed-release-notes \
	--download-url-prefix "https://github.com/garrill/Leaf/releases/download/v$VERSION/" \
	"$STAGING"

cp "$STAGING/appcast.xml" appcast.xml

echo "Updated appcast.xml with $DMG_PATH (version $VERSION)."
echo "Next: commit appcast.xml + CHANGELOG.md, tag/push a GitHub Release, and attach $DMG_PATH as its asset."
echo "The <enclosure url> in appcast.xml must exactly match that release asset's download URL."
