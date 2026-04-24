#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Monthly Video Generator"
EXECUTABLE_NAME="MonthlyVideoGeneratorApp"
BUNDLE_ID="com.jkfisher.MonthlyVideoGenerator"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
DIST_DIR="$ROOT_DIR/dist"
FINAL_APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
APP_BUNDLE=""
CONTENTS_DIR=""
MACOS_DIR=""
RESOURCES_DIR=""
FRAMEWORKS_DIR=""
THIRD_PARTY_FFMPEG_ROOT="$ROOT_DIR/third_party/ffmpeg"
ICON_NAME="AppIcon"
ICON_GENERATOR_SCRIPT="$ROOT_DIR/scripts/generate_app_icon.swift"
MINIMUM_SYSTEM_VERSION="15.0"
DEFAULT_APP_ARCHS="arm64 x86_64"
APP_ARCHS="${APP_ARCHS:-$DEFAULT_APP_ARCHS}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
ICON_TEMP_DIR=""
PACKAGING_TEMP_DIR=""

cleanup() {
  if [[ -n "$ICON_TEMP_DIR" && -d "$ICON_TEMP_DIR" ]]; then
    rm -rf "$ICON_TEMP_DIR"
  fi
  if [[ -n "$PACKAGING_TEMP_DIR" && -d "$PACKAGING_TEMP_DIR" ]]; then
    rm -rf "$PACKAGING_TEMP_DIR"
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

read -r -a BUILD_ARCHS <<< "$APP_ARCHS"
if [[ "${#BUILD_ARCHS[@]}" -eq 0 ]]; then
  echo "Error: APP_ARCHS must contain at least one architecture (for example: 'arm64 x86_64')." >&2
  exit 1
fi

PACKAGING_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monthly-video-generator-app.XXXXXX")"
APP_BUNDLE="$PACKAGING_TEMP_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

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

validate_tool_launch() {
  local tool_path="$1"
  local label="$2"
  shift 2
  local -a required_archs=("$@")

  if [[ ! -x "$tool_path" ]]; then
    echo "Error: required bundled $label is missing or not executable at $tool_path." >&2
    exit 1
  fi

  if ! "$tool_path" -version >/dev/null 2>&1; then
    echo "Error: required bundled $label exists but failed to launch at $tool_path." >&2
    "$tool_path" -version >&2 || true
    exit 1
  fi

  if command -v lipo >/dev/null 2>&1; then
    if ! lipo "$tool_path" -verify_arch "${required_archs[@]}" >/dev/null 2>&1; then
      echo "Error: required bundled $label at $tool_path does not contain architectures: ${required_archs[*]}." >&2
      lipo -info "$tool_path" >&2 || true
      exit 1
    fi
  fi
}

ffmpeg_arch_dir() {
  local arch="$1"
  case "$arch" in
    arm64)
      printf '%s\n' "$THIRD_PARTY_FFMPEG_ROOT/darwin-arm64"
      ;;
    x86_64)
      printf '%s\n' "$THIRD_PARTY_FFMPEG_ROOT/darwin-x64"
      ;;
    *)
      echo "Error: no bundled FFmpeg slice is configured for architecture '$arch'." >&2
      exit 1
      ;;
  esac
}

ffmpeg_slice_path() {
  local arch="$1"
  local tool="$2"
  printf '%s/%s\n' "$(ffmpeg_arch_dir "$arch")" "$tool"
}

cd "$ROOT_DIR"

for arch in "${BUILD_ARCHS[@]}"; do
  validate_tool_launch "$(ffmpeg_slice_path "$arch" ffmpeg)" "ffmpeg $arch" "$arch"
  validate_tool_launch "$(ffmpeg_slice_path "$arch" ffprobe)" "ffprobe $arch" "$arch"
done

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
ditto --noextattr --noqtn "$ICON_OUTPUT" "$RESOURCES_DIR/${ICON_NAME}.icns"

mkdir -p "$RESOURCES_DIR/FFmpeg"
FFMPEG_SLICE_PATHS=()
FFPROBE_SLICE_PATHS=()
for arch in "${BUILD_ARCHS[@]}"; do
  FFMPEG_SLICE_PATHS+=("$(ffmpeg_slice_path "$arch" ffmpeg)")
  FFPROBE_SLICE_PATHS+=("$(ffmpeg_slice_path "$arch" ffprobe)")
done
if [[ "${#BUILD_ARCHS[@]}" -eq 1 ]]; then
  ditto --noextattr --noqtn "${FFMPEG_SLICE_PATHS[0]}" "$RESOURCES_DIR/FFmpeg/ffmpeg"
  ditto --noextattr --noqtn "${FFPROBE_SLICE_PATHS[0]}" "$RESOURCES_DIR/FFmpeg/ffprobe"
else
  lipo -create "${FFMPEG_SLICE_PATHS[@]}" -output "$RESOURCES_DIR/FFmpeg/ffmpeg"
  lipo -create "${FFPROBE_SLICE_PATHS[@]}" -output "$RESOURCES_DIR/FFmpeg/ffprobe"
fi
chmod +x "$RESOURCES_DIR/FFmpeg/ffmpeg" "$RESOURCES_DIR/FFmpeg/ffprobe"
validate_tool_launch "$RESOURCES_DIR/FFmpeg/ffmpeg" "packaged ffmpeg" "${BUILD_ARCHS[@]}"
validate_tool_launch "$RESOURCES_DIR/FFmpeg/ffprobe" "packaged ffprobe" "${BUILD_ARCHS[@]}"
echo "Bundled FFmpeg binaries from: $THIRD_PARTY_FFMPEG_ROOT"

if [[ -n "$RESOURCE_SOURCE_DIR" ]]; then
  while IFS= read -r resource_bundle; do
    ditto --noextattr --noqtn "$resource_bundle" "$RESOURCES_DIR/$(basename "$resource_bundle")"
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
  <string>$CURRENT_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_SYSTEM_VERSION</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
    <string>x86_64</string>
  </array>
  <key>LSRequiresNativeExecution</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Monthly Video Generator needs access to your photos to build month-based slideshows.</string>
</dict>
</plist>
PLIST

chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

codesign_target "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

rm -rf "$FINAL_APP_BUNDLE"
mkdir -p "$DIST_DIR"
ditto --noextattr --noqtn "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
xattr -cr "$FINAL_APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$FINAL_APP_BUNDLE"

echo "Built app bundle: $FINAL_APP_BUNDLE"
echo "Version: $APP_VERSION ($CURRENT_BUILD_NUMBER)"
echo "Architectures: ${BUILD_ARCHS[*]}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Signing: ad-hoc"
else
  echo "Signing identity: $CODESIGN_IDENTITY"
fi
