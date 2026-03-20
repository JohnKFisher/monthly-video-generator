#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Monthly Video Generator"
EXECUTABLE_NAME="MonthlyVideoGeneratorApp"
BUNDLE_ID="com.jkfisher.MonthlyVideoGenerator"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
THIRD_PARTY_FFMPEG_BIN_DIR="$ROOT_DIR/third_party/ffmpeg/bin"
ICON_NAME="AppIcon"
ICON_GENERATOR_SCRIPT="$ROOT_DIR/scripts/generate_app_icon.swift"
MINIMUM_SYSTEM_VERSION="15.0"
DEFAULT_APP_ARCHS="arm64 x86_64"
APP_ARCHS="${APP_ARCHS:-$DEFAULT_APP_ARCHS}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
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

if [[ ! -f "$BUILD_NUMBER_FILE" ]]; then
  echo "Error: missing build number file at $BUILD_NUMBER_FILE." >&2
  exit 1
fi

CURRENT_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
if [[ ! "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: BUILD_NUMBER must contain an integer, found '$CURRENT_BUILD_NUMBER'." >&2
  exit 1
fi

NEXT_BUILD_NUMBER="$((CURRENT_BUILD_NUMBER + 1))"

read -r -a BUILD_ARCHS <<< "$APP_ARCHS"
if [[ "${#BUILD_ARCHS[@]}" -eq 0 ]]; then
  echo "Error: APP_ARCHS must contain at least one architecture (for example: 'arm64 x86_64')." >&2
  exit 1
fi

BIN_PATHS=()
RESOURCE_SOURCE_DIR=""

build_release_slice() {
  local arch="$1"
  local triple="${arch}-apple-macosx${MINIMUM_SYSTEM_VERSION}"
  local bin_path
  local executable_path

  echo "Building release slice for ${arch} (${triple})..."
  swift build -c release --product "$EXECUTABLE_NAME" --triple "$triple"
  bin_path="$(swift build -c release --product "$EXECUTABLE_NAME" --triple "$triple" --show-bin-path)"
  executable_path="$bin_path/$EXECUTABLE_NAME"

  if [[ ! -f "$executable_path" ]]; then
    echo "Error: built executable missing at $executable_path." >&2
    exit 1
  fi

  if [[ -z "$RESOURCE_SOURCE_DIR" ]]; then
    RESOURCE_SOURCE_DIR="$bin_path"
  fi

  remove_nonportable_rpaths "$executable_path"
  ensure_rpath "$executable_path" "@executable_path/../Frameworks"

  BIN_PATHS+=("$executable_path")
}

current_rpaths() {
  local binary="$1"
  otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

remove_nonportable_rpaths() {
  local binary="$1"
  local rpath

  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode.app/*|/Library/Developer/Toolchains/*)
        install_name_tool -delete_rpath "$rpath" "$binary"
        ;;
    esac
  done < <(current_rpaths "$binary")
}

ensure_rpath() {
  local binary="$1"
  local required_rpath="$2"

  if ! current_rpaths "$binary" | grep -Fx "$required_rpath" >/dev/null 2>&1; then
    install_name_tool -add_rpath "$required_rpath" "$binary"
  fi
}

codesign_target() {
  local target="$1"
  local -a codesign_args=(--force --sign "$CODESIGN_IDENTITY")

  if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime)
  fi

  codesign "${codesign_args[@]}" "$target"
}

cd "$ROOT_DIR"

for arch in "${BUILD_ARCHS[@]}"; do
  build_release_slice "$arch"
done

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

if [[ "${#BIN_PATHS[@]}" -eq 1 ]]; then
  cp "${BIN_PATHS[0]}" "$MACOS_DIR/$EXECUTABLE_NAME"
else
  lipo -create "${BIN_PATHS[@]}" -output "$MACOS_DIR/$EXECUTABLE_NAME"
fi
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

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
cp "$ICON_OUTPUT" "$RESOURCES_DIR/${ICON_NAME}.icns"

if [[ -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" && -x "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" ]]; then
  mkdir -p "$RESOURCES_DIR/FFmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffmpeg" "$RESOURCES_DIR/FFmpeg/ffmpeg"
  cp "$THIRD_PARTY_FFMPEG_BIN_DIR/ffprobe" "$RESOURCES_DIR/FFmpeg/ffprobe"
  chmod +x "$RESOURCES_DIR/FFmpeg/ffmpeg" "$RESOURCES_DIR/FFmpeg/ffprobe"
  echo "Bundled FFmpeg binaries from: $THIRD_PARTY_FFMPEG_BIN_DIR"
else
  echo "No bundled FFmpeg binaries found at $THIRD_PARTY_FFMPEG_BIN_DIR (the app will require explicit approval before any system FFmpeg fallback)."
fi

if [[ -n "$RESOURCE_SOURCE_DIR" ]]; then
  while IFS= read -r resource_bundle; do
    cp -R "$resource_bundle" "$RESOURCES_DIR/"
  done < <(find "$RESOURCE_SOURCE_DIR" -maxdepth 1 -type d -name "*.bundle" | sort)
fi

xcrun swift-stdlib-tool \
  --copy \
  --platform macosx \
  --scan-executable "$MACOS_DIR/$EXECUTABLE_NAME" \
  --destination "$FRAMEWORKS_DIR"

while IFS= read -r dylib; do
  codesign_target "$dylib"
done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type f -name "*.dylib" | sort)

if [[ -x "$RESOURCES_DIR/FFmpeg/ffmpeg" ]]; then
  codesign_target "$RESOURCES_DIR/FFmpeg/ffmpeg"
fi
if [[ -x "$RESOURCES_DIR/FFmpeg/ffprobe" ]]; then
  codesign_target "$RESOURCES_DIR/FFmpeg/ffprobe"
fi

codesign_target "$MACOS_DIR/$EXECUTABLE_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
  <string>$NEXT_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Monthly Video Generator needs access to your photos to build month-based slideshows.</string>
</dict>
</plist>
PLIST

codesign_target "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

temp_build_number_file="$(mktemp "${TMPDIR:-/tmp}/monthly-video-generator-build-number.XXXXXX")"
printf '%s\n' "$NEXT_BUILD_NUMBER" > "$temp_build_number_file"
mv "$temp_build_number_file" "$BUILD_NUMBER_FILE"

echo "Built app bundle: $APP_BUNDLE"
echo "Version: $APP_VERSION ($NEXT_BUILD_NUMBER)"
echo "Architectures: ${BUILD_ARCHS[*]}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Signing: ad-hoc"
else
  echo "Signing identity: $CODESIGN_IDENTITY"
fi
