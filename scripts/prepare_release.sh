#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${VERSION_FILE:-$ROOT_DIR/VERSION}"
BUILD_NUMBER_FILE="${BUILD_NUMBER_FILE:-$ROOT_DIR/BUILD_NUMBER}"
DEFAULT_VERSION_FILE="$ROOT_DIR/VERSION"
DEFAULT_BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"

resolve_path() {
  local target="$1"
  local parent

  parent="$(cd "$(dirname "$target")" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$target")"
}

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Error: missing version file at $VERSION_FILE." >&2
  exit 1
fi

if [[ ! -f "$BUILD_NUMBER_FILE" ]]; then
  echo "Error: missing build number file at $BUILD_NUMBER_FILE." >&2
  exit 1
fi

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Error: VERSION must use semantic version format X.Y.Z, found '$CURRENT_VERSION'." >&2
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

CURRENT_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
if [[ ! "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: BUILD_NUMBER must contain an integer, found '$CURRENT_BUILD_NUMBER'." >&2
  exit 1
fi

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ "$(resolve_path "$VERSION_FILE")" == "$(resolve_path "$DEFAULT_VERSION_FILE")" ]] \
  && [[ "$(resolve_path "$BUILD_NUMBER_FILE")" == "$(resolve_path "$DEFAULT_BUILD_NUMBER_FILE")" ]]; then
  if ! git -C "$ROOT_DIR" diff --quiet -- "$VERSION_FILE" "$BUILD_NUMBER_FILE"; then
    echo "Error: VERSION or BUILD_NUMBER already has uncommitted changes. Review those files before preparing a new release." >&2
    exit 1
  fi
fi

NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
NEXT_BUILD_NUMBER="$((CURRENT_BUILD_NUMBER + 1))"

temp_version_file="$(mktemp "${TMPDIR:-/tmp}/monthly-video-generator-version.XXXXXX")"
temp_build_file="$(mktemp "${TMPDIR:-/tmp}/monthly-video-generator-build.XXXXXX")"
trap 'rm -f "$temp_version_file" "$temp_build_file"' EXIT

printf '%s\n' "$NEXT_VERSION" > "$temp_version_file"
printf '%s\n' "$NEXT_BUILD_NUMBER" > "$temp_build_file"

mv "$temp_version_file" "$VERSION_FILE"
mv "$temp_build_file" "$BUILD_NUMBER_FILE"

echo "Prepared release version: $NEXT_VERSION ($NEXT_BUILD_NUMBER)"
echo "Updated files:"
echo "- $VERSION_FILE"
echo "- $BUILD_NUMBER_FILE"
