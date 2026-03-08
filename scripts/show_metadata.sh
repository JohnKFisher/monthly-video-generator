#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLED_FFPROBE="$ROOT_DIR/third_party/ffmpeg/bin/ffprobe"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/show_metadata.sh [--all] [--ffprobe-only] [--json] <file.mp4>

Examples:
  ./scripts/show_metadata.sh "/path/to/video.mp4"
  ./scripts/show_metadata.sh --json "/path/to/video.mp4"

Notes:
  - Prefers exiftool when available because it shows QuickTime Keys (`mdta`) tags clearly.
  - Default exiftool output is focused on file info plus metadata namespaces that are most relevant for Plex and post-export inspection.
  - Falls back to ffprobe JSON if exiftool is unavailable or --ffprobe-only is used.
USAGE
}

prefer_ffprobe=0
show_all=0
input_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ffprobe-only)
      prefer_ffprobe=1
      shift
      ;;
    --json)
      prefer_ffprobe=1
      shift
      ;;
    --all)
      show_all=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$input_path" ]]; then
        echo "Only one input file is supported." >&2
        usage >&2
        exit 1
      fi
      input_path="$1"
      shift
      ;;
  esac
done

if [[ -z "$input_path" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$input_path" ]]; then
  echo "Input file does not exist: $input_path" >&2
  exit 1
fi

if [[ $prefer_ffprobe -eq 0 ]] && command -v exiftool >/dev/null 2>&1; then
  if [[ $show_all -eq 1 ]]; then
    exiftool -G1 -a -s "$input_path"
  else
    exiftool \
      -G1 \
      -a \
      -s \
      -System:FileName \
      -System:Directory \
      -File:FileType \
      -File:MIMEType \
      -QuickTime:CreateDate \
      -QuickTime:ModifyDate \
      -Keys:All \
      -ItemList:All \
      -UserData:All \
      "$input_path"
  fi
  exit 0
fi

if [[ -x "$BUNDLED_FFPROBE" ]]; then
  FFPROBE_BIN="$BUNDLED_FFPROBE"
elif command -v ffprobe >/dev/null 2>&1; then
  FFPROBE_BIN="$(command -v ffprobe)"
else
  echo "No ffprobe binary found. Install ffprobe or bundle it into third_party/ffmpeg/bin." >&2
  exit 1
fi

exec "$FFPROBE_BIN" \
  -v quiet \
  -print_format json \
  -show_entries format_tags:stream_tags \
  "$input_path"
