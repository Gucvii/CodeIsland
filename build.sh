#!/bin/bash
set -e

APP_NAME="CodeIsland"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_CATALOG="Assets.xcassets"
ICON_SOURCE="AppIcon.icon"
ICON_INFO_PLIST=".build/AppIcon.partial.plist"

echo "Building $APP_NAME (universal)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

echo "Creating universal binaries..."
ARM_DIR=".build/arm64-apple-macosx/release"
X86_DIR=".build/x86_64-apple-macosx/release"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" \
     -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
     -output "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "Compiling app icon assets..."
xcrun actool \
    --output-format human-readable-text \
    --warnings \
    --errors \
    --notices \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_INFO_PLIST" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    "$ICON_CATALOG" \
    "$ICON_SOURCE"

# Copy SPM resource bundles — place at .app root where Bundle.module expects them
for bundle in .build/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/"
        break
    fi
done

echo "Ad-hoc code signing..."
codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"
