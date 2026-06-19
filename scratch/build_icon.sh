#!/bin/bash
set -e

# Source files
ICON_128="2fe8c67e-41c7-4e04-adb0-919fa223b6af.png"
ICON_1024="5b120894-35ca-41b1-b264-800aec2ece55.png"
ICONSET="AppIcon.iconset"
OUTPUT="NTFSMagic/AppIcon.icns"

echo "Creating iconset directory..."
mkdir -p "$ICONSET"

# Resize images from the high resolution source
echo "Generating icon resolutions..."
sips -z 16 16     "$ICON_128" --out "$ICONSET/icon_16x16.png"
sips -z 32 32     "$ICON_128" --out "$ICONSET/icon_16x16@2x.png"
sips -z 32 32     "$ICON_128" --out "$ICONSET/icon_32x32.png"
sips -z 64 64     "$ICON_128" --out "$ICONSET/icon_32x32@2x.png"
sips -z 128 128   "$ICON_128" --out "$ICONSET/icon_128x128.png"
sips -z 256 256   "$ICON_1024" --out "$ICONSET/icon_128x128@2x.png"
sips -z 256 256   "$ICON_1024" --out "$ICONSET/icon_256x256.png"
sips -z 512 512   "$ICON_1024" --out "$ICONSET/icon_256x256@2x.png"
sips -z 512 512   "$ICON_1024" --out "$ICONSET/icon_512x512.png"
sips -z 1024 1024 "$ICON_1024" --out "$ICONSET/icon_512x512@2x.png"

echo "Compiling icns file using iconutil..."
iconutil -c icns "$ICONSET" -o "$OUTPUT"

echo "Copying original logo PNGs for app UI..."
cp "$ICON_128" NTFSMagic/logo_128.png
cp "$ICON_1024" NTFSMagic/logo_1024.png

echo "Cleaning up iconset directory..."
rm -rf "$ICONSET"

echo "Success! Icon compiled to $OUTPUT"
