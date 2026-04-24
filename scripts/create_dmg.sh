#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${VERSION_FILE:-$ROOT_DIR/VERSION}"
BUILD_NUMBER_FILE="${BUILD_NUMBER_FILE:-$ROOT_DIR/BUILD_NUMBER}"
DEFAULT_APP_PATH="$ROOT_DIR/dist/Monthly Video Generator.app"
DEFAULT_OUTPUT_DIR="$ROOT_DIR/dist"

APP_PATH="${APP_PATH:-$DEFAULT_APP_PATH}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
OUTPUT_PATH="${OUTPUT_PATH:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output-path)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--app-path /path/to/app] [--output-dir /path/to/dist] [--output-path /path/to/file.dmg]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Error: missing version file at $VERSION_FILE." >&2
  exit 1
fi

if [[ ! -f "$BUILD_NUMBER_FILE" ]]; then
  echo "Error: missing build number file at $BUILD_NUMBER_FILE." >&2
  exit 1
fi

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found at $APP_PATH." >&2
  exit 1
fi

architecture_label() {
  local executable_path="$1"
  local archs

  if ! archs="$(lipo -archs "$executable_path" 2>/dev/null)"; then
    echo "unknown"
    return
  fi

  if [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; then
    echo "universal"
  elif [[ " $archs " == *" arm64 "* ]]; then
    echo "arm64"
  elif [[ " $archs " == *" x86_64 "* ]]; then
    echo "x86_64"
  else
    echo "${archs// /-}"
  fi
}

if [[ -z "$OUTPUT_PATH" ]]; then
  mkdir -p "$OUTPUT_DIR"
  APP_EXECUTABLE="$APP_PATH/Contents/MacOS/MonthlyVideoGeneratorApp"
  OUTPUT_ARCH_LABEL="$(architecture_label "$APP_EXECUTABLE")"
  OUTPUT_PATH="$OUTPUT_DIR/Monthly-Video-Generator-v${APP_VERSION}-build-${BUILD_NUMBER}-macOS-${OUTPUT_ARCH_LABEL}.dmg"
fi

if [[ -e "$OUTPUT_PATH" ]]; then
  echo "Error: refusing to overwrite existing DMG at $OUTPUT_PATH." >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/monthly-video-generator-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

STAGED_APP_PATH="$staging_dir/$(basename "$APP_PATH")"
ditto "$APP_PATH" "$STAGED_APP_PATH"
chmod -R u+w "$STAGED_APP_PATH"
xattr -cr "$STAGED_APP_PATH"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH" >/dev/null

hdiutil create \
  -volname "Monthly Video Generator" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  "$OUTPUT_PATH" >/dev/null

echo "Created DMG: $OUTPUT_PATH"
