#!/usr/bin/env bash
set -euo pipefail

# Fetches pinned ffmpeg/ffprobe binaries into third_party/ffmpeg/bin.
# Supports archive URLs (zip/tar.*) or direct binary URLs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT_DIR/third_party/ffmpeg/bin"
TMP_DIR="${TMPDIR:-/tmp}/mvg-ffmpeg-fetch-$$"

FFMPEG_BUNDLE_URL="${FFMPEG_BUNDLE_URL:-}"
FFMPEG_BUNDLE_SHA256="${FFMPEG_BUNDLE_SHA256:-}"
FFPROBE_BUNDLE_URL="${FFPROBE_BUNDLE_URL:-}"
FFPROBE_BUNDLE_SHA256="${FFPROBE_BUNDLE_SHA256:-}"

if [[ -z "$FFMPEG_BUNDLE_URL" || -z "$FFMPEG_BUNDLE_SHA256" ]]; then
  cat <<USAGE
Usage:
  FFMPEG_BUNDLE_URL="https://.../ffmpeg-bundle.tar.gz" \
  FFMPEG_BUNDLE_SHA256="<sha256>" \
  [FFPROBE_BUNDLE_URL="https://.../ffprobe-binary"] \
  [FFPROBE_BUNDLE_SHA256="<sha256>"] \
  ./scripts/fetch_ffmpeg_bundle.sh

Notes:
  - FFMPEG_BUNDLE_* is required.
  - Use FFPROBE_BUNDLE_* for strict version matching from the same source.
  - If FFPROBE_BUNDLE_URL is not provided, script tries to find ffprobe in the ffmpeg payload,
    then falls back to ffprobe from PATH.
USAGE
  exit 1
fi

if [[ -n "$FFPROBE_BUNDLE_URL" && -z "$FFPROBE_BUNDLE_SHA256" ]]; then
  echo "FFPROBE_BUNDLE_SHA256 is required when FFPROBE_BUNDLE_URL is set."
  exit 1
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

verify_sha256() {
  local file_path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $file_path"
    echo "Expected: $expected"
    echo "Actual:   $actual"
    return 1
  fi
}

download_payload() {
  local url="$1"
  local output="$2"
  printf 'Downloading %s...\n' "$url"
  curl --fail --location --silent --show-error "$url" --output "$output"
}

extract_binary_from_payload() {
  local payload_url="$1"
  local payload_file="$2"
  local binary_name="$3"
  local output_file="$4"
  local extract_dir="$TMP_DIR/extract-$binary_name-$(date +%s%N)"
  mkdir -p "$extract_dir"
  rm -f "$output_file"

  if [[ "$payload_url" == *.zip ]]; then
    ditto -x -k "$payload_file" "$extract_dir"
  elif [[ "$payload_url" == *.tar.gz || "$payload_url" == *.tgz ]]; then
    tar -xzf "$payload_file" -C "$extract_dir"
  elif [[ "$payload_url" == *.tar.xz ]]; then
    tar -xJf "$payload_file" -C "$extract_dir"
  elif [[ "$payload_url" == *.gz ]]; then
    gunzip -c "$payload_file" > "$output_file" || return 1
    chmod +x "$output_file" || return 1
    return 0
  else
    cp "$payload_file" "$output_file" || return 1
    chmod +x "$output_file" || return 1
    return 0
  fi

  local found
  found="$(find "$extract_dir" -type f -name "$binary_name" | head -n 1 || true)"
  if [[ -z "$found" ]]; then
    return 1
  fi

  cp "$found" "$output_file" || return 1
  chmod +x "$output_file" || return 1
  return 0
}

FFMPEG_PAYLOAD="$TMP_DIR/ffmpeg-payload"
download_payload "$FFMPEG_BUNDLE_URL" "$FFMPEG_PAYLOAD"
verify_sha256 "$FFMPEG_PAYLOAD" "$FFMPEG_BUNDLE_SHA256"

mkdir -p "$DEST_DIR"
FFMPEG_DEST="$DEST_DIR/ffmpeg"
FFPROBE_DEST="$DEST_DIR/ffprobe"

if ! extract_binary_from_payload "$FFMPEG_BUNDLE_URL" "$FFMPEG_PAYLOAD" "ffmpeg" "$FFMPEG_DEST"; then
  echo "Failed to locate ffmpeg in payload: $FFMPEG_BUNDLE_URL"
  exit 1
fi

FFPROBE_SOURCE_PATH=""
if [[ -n "$FFPROBE_BUNDLE_URL" ]]; then
  FFPROBE_PAYLOAD="$TMP_DIR/ffprobe-payload"
  download_payload "$FFPROBE_BUNDLE_URL" "$FFPROBE_PAYLOAD"
  verify_sha256 "$FFPROBE_PAYLOAD" "$FFPROBE_BUNDLE_SHA256"
  if ! extract_binary_from_payload "$FFPROBE_BUNDLE_URL" "$FFPROBE_PAYLOAD" "ffprobe" "$FFPROBE_DEST"; then
    echo "Failed to locate ffprobe in payload: $FFPROBE_BUNDLE_URL"
    exit 1
  fi
  FFPROBE_SOURCE_PATH="$FFPROBE_BUNDLE_URL"
else
  if extract_binary_from_payload "$FFMPEG_BUNDLE_URL" "$FFMPEG_PAYLOAD" "ffprobe" "$FFPROBE_DEST"; then
    FFPROBE_SOURCE_PATH="$FFMPEG_BUNDLE_URL"
  else
    echo "Payload has no ffprobe; falling back to PATH lookup."
    SYSTEM_FFPROBE="$(command -v ffprobe || true)"
    if [[ -z "$SYSTEM_FFPROBE" ]]; then
      echo "No ffprobe found in PATH for fallback."
      exit 1
    fi
    rm -f "$FFPROBE_DEST"
    cp "$SYSTEM_FFPROBE" "$FFPROBE_DEST"
    chmod +x "$FFPROBE_DEST"
    FFPROBE_SOURCE_PATH="$SYSTEM_FFPROBE"
  fi
fi

mkdir -p "$ROOT_DIR/third_party/ffmpeg"
cat > "$ROOT_DIR/third_party/ffmpeg/PROVENANCE.txt" <<META
fetched_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ffmpeg_url=$FFMPEG_BUNDLE_URL
ffmpeg_sha256=$FFMPEG_BUNDLE_SHA256
ffprobe_url=${FFPROBE_BUNDLE_URL:-none}
ffprobe_sha256=${FFPROBE_BUNDLE_SHA256:-none}
installed_ffmpeg=$FFMPEG_DEST
installed_ffprobe=$FFPROBE_DEST
source_ffprobe=$FFPROBE_SOURCE_PATH
META

printf 'Installed FFmpeg bundle to %s\n' "$DEST_DIR"
