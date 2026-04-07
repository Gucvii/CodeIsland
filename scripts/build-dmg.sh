#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build-dmg.sh <version>
# Example: ./scripts/build-dmg.sh 1.0.7

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
RELEASE_DIR="$BUILD_DIR/release"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/CodeIsland.app"
CONTENTS_DIR="$APP_DIR/Contents"
OUTPUT_DMG="$BUILD_DIR/CodeIsland.dmg"

echo "==> Building CodeIsland ${VERSION} (universal)"

# Build for both architectures
cd "$REPO_ROOT"
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_DIR="$BUILD_DIR/arm64-apple-macosx/release"
X86_DIR="$BUILD_DIR/x86_64-apple-macosx/release"

echo "==> Assembling .app bundle"

# Clean and recreate staging
rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
mkdir -p "$CONTENTS_DIR/Helpers"
mkdir -p "$CONTENTS_DIR/Resources"

# Create universal binaries
lipo -create "$ARM_DIR/CodeIsland" "$X86_DIR/CodeIsland" \
     -output "$CONTENTS_DIR/MacOS/CodeIsland"
lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
     -output "$CONTENTS_DIR/Helpers/codeisland-bridge"

# Write Info.plist (use the root Info.plist as base, update version)
sed -e "s/<string>1\.0\.6<\/string>/<string>${VERSION}<\/string>/g" \
    "$REPO_ROOT/Info.plist" > "$CONTENTS_DIR/Info.plist"

# Copy pre-built app icon (actool + AppIcon.icon format unreliable on CI)
cp "$REPO_ROOT/Sources/CodeIsland/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

# Copy SPM resource bundles at .app root where Bundle.module expects them
for bundle in "$BUILD_DIR"/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP_DIR/"
        break
    fi
done

echo "==> App bundle assembled at $APP_DIR"

# ---------------------------------------------------------------------------
# Code signing requires an Apple Developer account ($99/year).
# Without Developer ID signing + notarization, macOS Gatekeeper will block
# apps downloaded from the internet ("damaged" / "unidentified developer").
#
# Workaround for users: run  xattr -cr /Applications/CodeIsland.app
# Or install via Homebrew:  brew install wxtsky/tap/codeisland
#
# To enable signing, uncomment below and set your credentials:
# ---------------------------------------------------------------------------
# TEAM_ID="YOUR_TEAM_ID"
# SIGNING_IDENTITY="Developer ID Application: Your Name (${TEAM_ID})"
#
# codesign --deep --force --options runtime \
#     --entitlements "$REPO_ROOT/CodeIsland.entitlements" \
#     --sign "$SIGNING_IDENTITY" \
#     "$APP_DIR"
# ---------------------------------------------------------------------------

echo "==> Creating DMG"

# Remove previous DMG if exists
rm -f "$OUTPUT_DMG"

create-dmg \
    --volname "CodeIsland ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "CodeIsland.app" 175 190 \
    --hide-extension "CodeIsland.app" \
    --app-drop-link 425 190 \
    "$OUTPUT_DMG" \
    "$STAGING_DIR/"

# ---------------------------------------------------------------------------
# Notarization (uncomment after Developer ID signing)
# ---------------------------------------------------------------------------
# BUNDLE_ID="com.codeisland.app"
# APPLE_ID="your@apple.id"
# APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # app-specific password
#
# xcrun notarytool submit "$OUTPUT_DMG" \
#     --apple-id "$APPLE_ID" \
#     --password "$APP_PASSWORD" \
#     --team-id "$TEAM_ID" \
#     --wait
#
# xcrun stapler staple "$OUTPUT_DMG"
# ---------------------------------------------------------------------------

echo "==> Done: $OUTPUT_DMG"
