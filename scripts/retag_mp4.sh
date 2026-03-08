#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLED_FFMPEG="$ROOT_DIR/third_party/ffmpeg/bin/ffmpeg"
SHOW_SCRIPT="$ROOT_DIR/scripts/show_metadata.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/retag_mp4.sh --input <file.mp4> --output <new-file.mp4> [options]

Required:
  --input <path>                Source MP4 to remux.
  --output <path>               New MP4 path. Must not already exist.

Metadata options:
  --title <text>
  --show <text>
  --season-number <number>
  --episode-sort <number>
  --episode-id <text>
  --date <text>
  --creation-time <iso8601>
  --description <text>
  --synopsis <text>
  --comment <text>
  --genre <text>
  --software <text>
  --version <text>
  --information <text>
  --custom <key=value>           Adds a custom metadata entry. May be repeated.
  --description-all <text>      Sets description, synopsis, and comment together.

Safety:
  --dry-run                     Print the planned remux command without writing output.
  -h, --help                    Show this help.

Examples:
  ./scripts/retag_mp4.sh \
    --input "/path/in.mp4" \
    --output "/path/out.mp4" \
    --title "March 2026" \
    --show "Family Videos" \
    --season-number 2026 \
    --episode-sort 399 \
    --episode-id "S2026E0399" \
    --date 2026 \
    --description-all "Fisher Family Monthly Video for March 2026" \
    --genre Family
USAGE
}

input_path=""
output_path=""
dry_run=0

title=""
show=""
season_number=""
episode_sort=""
episode_id=""
date_value=""
creation_time=""
description=""
synopsis=""
comment=""
genre=""
software=""
version_value=""
information=""
custom_entries=()

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "Missing value for $option" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      require_value "$1" "${2:-}"
      input_path="${2:-}"
      shift 2
      ;;
    --output)
      require_value "$1" "${2:-}"
      output_path="${2:-}"
      shift 2
      ;;
    --title)
      require_value "$1" "${2:-}"
      title="${2:-}"
      shift 2
      ;;
    --show)
      require_value "$1" "${2:-}"
      show="${2:-}"
      shift 2
      ;;
    --season-number)
      require_value "$1" "${2:-}"
      season_number="${2:-}"
      shift 2
      ;;
    --episode-sort)
      require_value "$1" "${2:-}"
      episode_sort="${2:-}"
      shift 2
      ;;
    --episode-id)
      require_value "$1" "${2:-}"
      episode_id="${2:-}"
      shift 2
      ;;
    --date)
      require_value "$1" "${2:-}"
      date_value="${2:-}"
      shift 2
      ;;
    --creation-time)
      require_value "$1" "${2:-}"
      creation_time="${2:-}"
      shift 2
      ;;
    --description)
      require_value "$1" "${2:-}"
      description="${2:-}"
      shift 2
      ;;
    --synopsis)
      require_value "$1" "${2:-}"
      synopsis="${2:-}"
      shift 2
      ;;
    --comment)
      require_value "$1" "${2:-}"
      comment="${2:-}"
      shift 2
      ;;
    --genre)
      require_value "$1" "${2:-}"
      genre="${2:-}"
      shift 2
      ;;
    --software)
      require_value "$1" "${2:-}"
      software="${2:-}"
      shift 2
      ;;
    --version)
      require_value "$1" "${2:-}"
      version_value="${2:-}"
      shift 2
      ;;
    --information)
      require_value "$1" "${2:-}"
      information="${2:-}"
      shift 2
      ;;
    --custom)
      require_value "$1" "${2:-}"
      custom_entries+=("${2:-}")
      shift 2
      ;;
    --description-all)
      require_value "$1" "${2:-}"
      description="${2:-}"
      synopsis="${2:-}"
      comment="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
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
      echo "Unexpected positional argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$input_path" || -z "$output_path" ]]; then
  echo "--input and --output are required." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$input_path" ]]; then
  echo "Input file does not exist: $input_path" >&2
  exit 1
fi

if [[ -e "$output_path" ]]; then
  echo "Output already exists. Refusing to overwrite: $output_path" >&2
  exit 1
fi

output_dir="$(dirname "$output_path")"
if [[ ! -d "$output_dir" ]]; then
  echo "Output directory does not exist: $output_dir" >&2
  exit 1
fi

input_real="$(cd "$(dirname "$input_path")" && pwd)/$(basename "$input_path")"
output_real="$(cd "$output_dir" && pwd)/$(basename "$output_path")"
if [[ "$input_real" == "$output_real" ]]; then
  echo "Input and output must be different paths." >&2
  exit 1
fi

if [[ -x "$BUNDLED_FFMPEG" ]]; then
  FFMPEG_BIN="$BUNDLED_FFMPEG"
elif command -v ffmpeg >/dev/null 2>&1; then
  FFMPEG_BIN="$(command -v ffmpeg)"
else
  echo "No ffmpeg binary found. Install ffmpeg or bundle it into third_party/ffmpeg/bin." >&2
  exit 1
fi

metadata_args=()
metadata_preview=()

append_metadata() {
  local key="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    metadata_args+=("-metadata" "${key}=${value}")
    metadata_preview+=("${key}=${value}")
  fi
}

append_metadata "title" "$title"
append_metadata "show" "$show"
append_metadata "season_number" "$season_number"
append_metadata "episode_sort" "$episode_sort"
append_metadata "episode_id" "$episode_id"
append_metadata "date" "$date_value"
append_metadata "creation_time" "$creation_time"
append_metadata "description" "$description"
append_metadata "synopsis" "$synopsis"
append_metadata "comment" "$comment"
append_metadata "genre" "$genre"
append_metadata "software" "$software"
append_metadata "version" "$version_value"
append_metadata "information" "$information"

for entry in "${custom_entries[@]}"; do
  if [[ "$entry" != *=* ]]; then
    echo "Custom metadata must use key=value form: $entry" >&2
    exit 1
  fi
  custom_key="${entry%%=*}"
  custom_value="${entry#*=}"
  if [[ -z "$custom_key" ]]; then
    echo "Custom metadata key must not be empty: $entry" >&2
    exit 1
  fi
  append_metadata "$custom_key" "$custom_value"
done

if [[ ${#metadata_preview[@]} -eq 0 ]]; then
  echo "No metadata changes requested." >&2
  usage >&2
  exit 1
fi

command_args=(
  "$FFMPEG_BIN"
  -i "$input_path"
  -map 0
  -map_metadata 0
  -c copy
  -movflags use_metadata_tags
)
command_args+=("${metadata_args[@]}")
command_args+=("$output_path")

echo "Planned remux:"
echo "  input:  $input_path"
echo "  output: $output_path"
echo "  metadata changes:"
for item in "${metadata_preview[@]}"; do
  echo "    $item"
done

echo "  ffmpeg:"
printf '    %q ' "${command_args[@]}"
printf '\n'

if [[ $dry_run -eq 1 ]]; then
  exit 0
fi

"${command_args[@]}"

if [[ -x "$SHOW_SCRIPT" ]]; then
  echo
  echo "Written metadata:"
  "$SHOW_SCRIPT" "$output_path"
fi
