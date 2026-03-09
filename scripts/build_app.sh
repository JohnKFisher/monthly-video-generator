#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Monthly Video Generator"
EXECUTABLE_NAME="MonthlyVideoGeneratorApp"
BUNDLE_ID="com.jkfisher.MonthlyVideoGenerator"
VERSION_FILE="$ROOT_DIR/VERSION"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
THIRD_PARTY_FFMPEG_BIN_DIR="$ROOT_DIR/third_party/ffmpeg/bin"
ICON_NAME="AppIcon"
ICON_GENERATOR_SCRIPT="$ROOT_DIR/scripts/generate_app_icon.swift"
ICON_TEMP_DIR=""

cleanup() {
  if [[ -n "$ICON_TEMP_DIR" && -d "$ICON_TEMP_DIR" ]]; then
    rm -rf "$ICON_TEMP_DIR"
  fi
}

trap cleanup EXIT

if [[ -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  APP_VERSION="0.1.0"
fi

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="0.1.0"
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"

cd "$ROOT_DIR"
swift build

EXECUTABLE_PATH=".build/debug/$EXECUTABLE_NAME"
if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  EXECUTABLE_PATH="$(find .build -path "*/debug/$EXECUTABLE_NAME" -type f | head -n 1)"
fi

if [[ -z "$EXECUTABLE_PATH" || ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Error: could not find built executable '$EXECUTABLE_NAME'." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

if [[ ! -f "$ICON_GENERATOR_SCRIPT" ]]; then
  echo "Error: missing icon generator script at $ICON_GENERATOR_SCRIPT." >&2
  exit 1
fi

ICON_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monthly-video-generator-icon.XXXXXX")"
ICONSET_DIR="$ICON_TEMP_DIR/${ICON_NAME}.iconset"
MASTER_ICON_PNG="$ICON_TEMP_DIR/${ICON_NAME}-1024.png"
ICON_OUTPUT="$ICON_TEMP_DIR/${ICON_NAME}.icns"

swift "$ICON_GENERATOR_SCRIPT" \
  --iconset-dir "$ICONSET_DIR" \
  --master-png "$MASTER_ICON_PNG"

iconutil --convert icns "$ICONSET_DIR" --output "$ICON_OUTPUT"
cp "$ICON_OUTPUT" "$APP_BUNDLE/Contents/Resources/${ICON_NAME}.icns"

if [[ -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" && -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/FFmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffprobe"
  chmod +x "$APP_BUNDLE/Contents/Resources/FFmpeg/ffmpeg" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffprobe"
  echo "Bundled FFmpeg binaries from: $THIRD_PARTY_FFMPEG_BIN_DIR"
else
  echo "No bundled FFmpeg binaries found at $THIRD_PARTY_FFMPEG_BIN_DIR (the app will require explicit approval before any system FFmpeg fallback)."
fi

while IFS= read -r resourceBundle; do
  cp -R "$resourceBundle" "$APP_BUNDLE/Contents/Resources/"
done < <(find .build -type d -name "*${EXECUTABLE_NAME}*.bundle" | sort)

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Monthly Video Generator needs access to your photos to build month-based slideshows.</string>
</dict>
</plist>
PLIST

echo "Built app bundle: $APP_BUNDLE"
echo "Version: $APP_VERSION ($BUILD_NUMBER)"
