#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MonthlyVideoGenerator"
EXECUTABLE_NAME="MonthlyVideoGeneratorApp"
BUNDLE_ID="com.jkfisher.MonthlyVideoGenerator"
VERSION_FILE="$ROOT_DIR/VERSION"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
THIRD_PARTY_FFMPEG_BIN_DIR="$ROOT_DIR/third_party/ffmpeg/bin"

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

if [[ -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" && -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/FFmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffprobe"
  chmod +x "$APP_BUNDLE/Contents/Resources/FFmpeg/ffmpeg" "$APP_BUNDLE/Contents/Resources/FFmpeg/ffprobe"
  echo "Bundled FFmpeg binaries from: $THIRD_PARTY_FFMPEG_BIN_DIR"
else
  echo "No bundled FFmpeg binaries found at $THIRD_PARTY_FFMPEG_BIN_DIR (system FFmpeg auto mode remains available)."
fi

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
