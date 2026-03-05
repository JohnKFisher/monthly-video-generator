#!/usr/bin/env bash
set -euo pipefail

# Fetches a pinned FFmpeg bundle and installs ffmpeg/ffprobe into third_party/ffmpeg/bin.
# Safe-by-default: caller must provide the exact archive URL and SHA256.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT_DIR/third_party/ffmpeg/bin"
TMP_DIR="${TMPDIR:-/tmp}/mvg-ffmpeg-fetch-$$"
ARCHIVE_PATH="$TMP_DIR/ffmpeg-bundle"

ARCHIVE_URL="${FFMPEG_BUNDLE_URL:-}"
ARCHIVE_SHA256="${FFMPEG_BUNDLE_SHA256:-}"

if [[ -z "$ARCHIVE_URL" || -z "$ARCHIVE_SHA256" ]]; then
  cat <<USAGE
Usage:
  FFMPEG_BUNDLE_URL="https://.../ffmpeg-bundle.zip" \
  FFMPEG_BUNDLE_SHA256="<sha256>" \
  ./scripts/fetch_ffmpeg_bundle.sh

Notes:
  - Provide a version-pinned archive URL and the expected SHA256.
  - Archive must contain arm64 macOS ffmpeg and ffprobe executables.
USAGE
  exit 1
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

printf 'Downloading FFmpeg bundle...\n'
curl --fail --location --silent --show-error "$ARCHIVE_URL" --output "$ARCHIVE_PATH"

printf 'Verifying SHA256...\n'
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$ARCHIVE_SHA256" ]]; then
  echo "Checksum mismatch."
  echo "Expected: $ARCHIVE_SHA256"
  echo "Actual:   $ACTUAL_SHA256"
  exit 1
fi

EXTRACT_DIR="$TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

if [[ "$ARCHIVE_URL" == *.zip ]]; then
  ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIR"
elif [[ "$ARCHIVE_URL" == *.tar.gz || "$ARCHIVE_URL" == *.tgz ]]; then
  tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
elif [[ "$ARCHIVE_URL" == *.tar.xz ]]; then
  tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
else
  echo "Unsupported archive type for URL: $ARCHIVE_URL"
  exit 1
fi

FFMPEG_PATH="$(find "$EXTRACT_DIR" -type f -name ffmpeg -perm -u+x | head -n 1 || true)"
FFPROBE_PATH="$(find "$EXTRACT_DIR" -type f -name ffprobe -perm -u+x | head -n 1 || true)"

if [[ -z "$FFMPEG_PATH" || -z "$FFPROBE_PATH" ]]; then
  echo "Failed to locate executable ffmpeg/ffprobe in extracted bundle."
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$FFMPEG_PATH" "$DEST_DIR/ffmpeg"
cp "$FFPROBE_PATH" "$DEST_DIR/ffprobe"
chmod +x "$DEST_DIR/ffmpeg" "$DEST_DIR/ffprobe"

cat > "$ROOT_DIR/third_party/ffmpeg/PROVENANCE.txt" <<META
fetched_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
archive_url=$ARCHIVE_URL
archive_sha256=$ARCHIVE_SHA256
installed_ffmpeg=$DEST_DIR/ffmpeg
installed_ffprobe=$DEST_DIR/ffprobe
META

printf 'Installed FFmpeg bundle to %s\n' "$DEST_DIR"
