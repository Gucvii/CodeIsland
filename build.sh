#!/bin/bash
set -e

APP_NAME="CodeIsland"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

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

# Generate app icon if not cached
if [ ! -f ".build/CodeIsland.icns" ]; then
    echo "Generating app icon..."
    ICONSET=".build/CodeIsland.iconset"
    mkdir -p "$ICONSET"
    qlmanage -t -s 1024 -o .build/ logo.svg 2>/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size ".build/logo.svg.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        double=$((size * 2))
        sips -z $double $double ".build/logo.svg.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o .build/CodeIsland.icns
fi
cp .build/CodeIsland.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy SPM resource bundles (pure resources, no lipo needed)
for bundle in .build/*/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"
