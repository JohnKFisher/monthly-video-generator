# Monthly Video Generator

Monthly Video Generator is a local-only macOS app that builds slideshow videos from media in folders and Apple Photos.

## Safety and Workflow

This project follows a strict milestone workflow:

1. Milestone updates are required when a stage gate is completed or behavior/scope/decisions materially change.
2. `docs/LIVING_PLAN.md` must be updated before claiming milestone completion.
3. Milestone checkpoint commits/tags must include the living document update.
4. Work is not complete unless the living document reflects current truth.

## Build

```bash
swift build
```

## Build `.app` Bundle

```bash
./scripts/build_app.sh
```

This creates:

- `dist/MonthlyVideoGenerator.app`

The build also generates a custom macOS `AppIcon.icns` from the repo-local Swift
icon renderer in `scripts/generate_app_icon.swift` and embeds it into the app bundle.

Optional override:

```bash
BUILD_NUMBER=42 ./scripts/build_app.sh
```

## Optional: Bundle FFmpeg For Final Export

To install pinned FFmpeg/ffprobe binaries into `third_party/ffmpeg/bin`:

```bash
FFMPEG_BUNDLE_URL="https://example.com/ffmpeg-arm64-gpl.zip" \
FFMPEG_BUNDLE_SHA256="<sha256>" \
[FFPROBE_BUNDLE_URL="https://example.com/ffprobe-arm64"] \
[FFPROBE_BUNDLE_SHA256="<sha256>"] \
./scripts/fetch_ffmpeg_bundle.sh
```

For strict version matching, set both `FFPROBE_BUNDLE_URL` and `FFPROBE_BUNDLE_SHA256`
from the same release/source as `FFMPEG_BUNDLE_URL`.

Then run:

```bash
./scripts/build_app.sh
```

If binaries are present, they are copied into:

- `dist/MonthlyVideoGenerator.app/Contents/Resources/FFmpeg/`

See:

- `docs/THIRD_PARTY.md`

## Inspect And Edit Plex MP4 Metadata

These helper scripts are for the QuickTime Keys (`mdta`) metadata written by the app's Plex-oriented MP4 exports.

Current exports write:

- Plex-facing tags such as `title`, `show`, `season_number`, `episode_sort`, `episode_id`, `description`, `synopsis`, and `comment`
- Named chapters on final `MP4` exports, including the opening title card plus one capture-date day chapter per day bucket
- Standard provenance tags `software`, `version`, and `information`
- App-specific custom keys under `com.jkfisher.monthlyvideogenerator.*`

Inspect an export:

```bash
./scripts/show_metadata.sh "/path/to/video.mp4"
```

That default view now includes a `[Chapters]` section when the file contains embedded chapter titles.

Force JSON output via `ffprobe`:

```bash
./scripts/show_metadata.sh --json "/path/to/video.mp4"
```

Rewrite metadata without re-encoding. This always writes a new file, refuses to overwrite an existing output, and supports `--dry-run`. The retag script can also update `software`, `version`, `information`, and repeated `--custom key=value` entries:

```bash
./scripts/retag_mp4.sh \
  --input "/path/to/input.mp4" \
  --output "/path/to/output.mp4" \
  --title "March 2026" \
  --show "Family Videos" \
  --season-number 2026 \
  --episode-sort 399 \
  --episode-id "S2026E0399" \
  --date 2026 \
  --description-all "Fisher Family Monthly Video for March 2026" \
  --genre "Family"
```

## Default Export Profile (Plex + Infuse on Apple TV 4K)

New default export profile for fresh installs (existing saved preferences are preserved):

- Container: `MP4`
- Video: `HEVC` (`hvc1` Main10 on HDR path)
- Frame rate: `Smart` (`30 fps` unless any selected video is `>= 50 fps`, then `60 fps`)
- Resolution: `Smart` (smallest `16:9` tier that fits all selected media, maximum `4K`)
- Dynamic range: `HDR` (HLG)
- Audio: `AAC Smart` (`Mono` unless any selected video needs `Stereo` or `5.1`)
- Bitrate mode: `Balanced`
- FFmpeg engine: `Auto (System then Bundled)`
- HDR HEVC Encoder: `Default` (`libx265` first, then `hevc_videotoolbox` if required)

Notes:

- In HDR mode, codec selection is constrained to effective renderer behavior (`HEVC`), but audio remains selectable (`Mono`, `Stereo`, `5.1`, `Smart`).
- In HDR mode, `HDR HEVC Encoder` can stay on `Default` for the current quality-first order or switch to `VideoToolbox` for faster hardware HEVC; explicit `VideoToolbox` selection fails if the chosen FFmpeg binary does not provide `hevc_videotoolbox`.
- SDR and HDR final exports both use the FFmpeg backend; still/title intermediate clips are still generated locally with AVFoundation.
- SDR exports that include HDR source videos now apply FFmpeg HDR-to-SDR tone mapping per affected video clip; HLG source videos use a retuned high-nominal-peak SDR conversion path before `BT.709` output so bright iPhone highlights land closer to the source look instead of clipping or washing out.
- In Apple Photos mode, Smart fps may inspect/download selected videos during render prep to decide between `30 fps` and `60 fps`, then reuse that materialized asset during export.
- In Apple Photos mode, Smart audio may inspect/download selected videos during render prep to choose `Mono`, `Stereo`, or `5.1`, and uninspectable videos fall back toward `5.1` to avoid dropping channels.
- Title cards are rendered at the resolved output size for both fixed-tier and Smart exports.
- Use the app's `Reset to Plex Defaults` action to apply this profile to an existing installation.

## Temporary Testing Controls

Current temporary test-only app behavior:

- The Output name field auto-generates a testing filename from the selected `Resolution`, `FPS`, `Range`, and `Audio`:
  `Testing - S2026E<unix epoch> - <Resolution> - <FPS>fps - <Range> - <Audio>`
- The field stays auto-managed until edited manually. `Use Auto Name` / `Regenerate` restores the temporary generated format.

## Known-Good Rollback

Current known-good rollback checkpoint (`v0.6.0`):

- `checkpoint/20260308-known-good-v0-6-0`

Previous known-good release checkpoint (`v0.5.0`):

- `checkpoint/20260307-known-good-v0-5-0`

Pre-FFmpeg-pivot rollback checkpoint:

- `checkpoint/20260304-known-good-pre-ffmpeg-pivot`

Rollback commands for current known-good:

```bash
git fetch --tags
git status
git checkout -b codex/recover-known-good-v0-6-0 checkpoint/20260308-known-good-v0-6-0
```

If you already have local changes you want to keep before rolling back, stash them first:

```bash
git stash push -u -m "pre-rollback safety stash"
```

To inspect the exact checkpoint without creating a branch:

```bash
git checkout checkpoint/20260308-known-good-v0-6-0
```

Checkpoint tags are kept under the repo's bounded-retention policy, so treat the current known-good tag and the previous release tag above as the supported rollback anchors.

## Test

```bash
swift test
```

## Run

```bash
swift run MonthlyVideoGeneratorApp
```
