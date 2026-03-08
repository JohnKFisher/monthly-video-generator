#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLED_FFPROBE="$ROOT_DIR/third_party/ffmpeg/bin/ffprobe"
CUSTOM_KEY_PREFIX="com.jkfisher.monthlyvideogenerator."

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
  - App-specific custom keys are surfaced from ffprobe under a [CustomKeys] section.
  - Final MP4 exports with embedded chapters print a [Chapters] section with start/end/title values.
  - Falls back to ffprobe JSON if exiftool is unavailable or --ffprobe-only is used.
USAGE
}

find_ffprobe() {
  if [[ -x "$BUNDLED_FFPROBE" ]]; then
    echo "$BUNDLED_FFPROBE"
    return 0
  fi

  if command -v ffprobe >/dev/null 2>&1; then
    command -v ffprobe
    return 0
  fi

  return 1
}

print_custom_keys() {
  local ffprobe_bin="$1"
  local raw_lines=""
  raw_lines="$(
    "$ffprobe_bin" \
      -v quiet \
      -show_entries format_tags \
      -of default=noprint_wrappers=1:nokey=0 \
      "$input_path" 2>/dev/null | grep "^TAG:${CUSTOM_KEY_PREFIX}" || true
  )"

  [[ -n "$raw_lines" ]] || return 0

  echo
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local trimmed="${line#TAG:}"
    local key="${trimmed%%=*}"
    local value="${trimmed#*=}"
    printf '[CustomKeys]    %-55s : %s\n' "$key" "$value"
  done <<< "$raw_lines"
}

format_timestamp() {
  local seconds="${1:-0}"
  awk -v total="$seconds" 'BEGIN {
    if (total < 0) total = 0
    hours = int(total / 3600)
    minutes = int((total - hours * 3600) / 60)
    secs = total - hours * 3600 - minutes * 60
    if (hours > 0) {
      printf "%d:%02d:%06.3f", hours, minutes, secs
    } else {
      printf "%02d:%06.3f", minutes, secs
    }
  }'
}

print_chapters() {
  local ffprobe_bin="$1"
  local raw_lines=""
  raw_lines="$(
    "$ffprobe_bin" \
      -v quiet \
      -show_entries chapter=start_time,end_time:chapter_tags=title \
      -of default=noprint_wrappers=0:nokey=0 \
      "$input_path" 2>/dev/null || true
  )"

  [[ -n "$raw_lines" ]] || return 0

  local start_time=""
  local end_time=""
  local title=""
  local chapter_index=0
  local emitted=0

  while IFS= read -r line; do
    case "$line" in
      "[CHAPTER]")
        start_time=""
        end_time=""
        title=""
        ;;
      start_time=*)
        start_time="${line#start_time=}"
        ;;
      end_time=*)
        end_time="${line#end_time=}"
        ;;
      TAG:title=*)
        title="${line#TAG:title=}"
        ;;
      "[/CHAPTER]")
        chapter_index=$((chapter_index + 1))
        if [[ $emitted -eq 0 ]]; then
          echo
          emitted=1
        fi
        printf '[Chapters]      #%d %-12s -> %-12s : %s\n' \
          "$chapter_index" \
          "$(format_timestamp "$start_time")" \
          "$(format_timestamp "$end_time")" \
          "${title:-<untitled>}"
        ;;
    esac
  done <<< "$raw_lines"
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

FFPROBE_BIN=""
if FFPROBE_BIN="$(find_ffprobe)"; then
  :
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
  if [[ -n "$FFPROBE_BIN" ]]; then
    print_custom_keys "$FFPROBE_BIN"
    print_chapters "$FFPROBE_BIN"
  fi
  exit 0
fi

if [[ -z "$FFPROBE_BIN" ]]; then
  echo "No ffprobe binary found. Install ffprobe or bundle it into third_party/ffmpeg/bin." >&2
  exit 1
fi

exec "$FFPROBE_BIN" \
  -v quiet \
  -print_format json \
  -show_entries format_tags:stream_tags:chapter=start_time,end_time:chapter_tags=title \
  -show_chapters \
  "$input_path"
