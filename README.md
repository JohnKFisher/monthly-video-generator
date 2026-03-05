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

Optional override:

```bash
BUILD_NUMBER=42 ./scripts/build_app.sh
```

## Optional: Bundle FFmpeg For HDR

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

## Default Export Profile (Plex + Infuse on Apple TV 4K)

New default export profile for fresh installs (existing saved preferences are preserved):

- Container: `MP4`
- Video: `HEVC` (`hvc1` Main10 on HDR path)
- Resolution: `Smart` (smallest `16:9` tier that fits all selected media, maximum `4K`)
- Dynamic range: `HDR` (HLG)
- Audio: `AAC stereo`
- Bitrate mode: `Balanced`
- HDR engine: `Auto (System then Bundled)`

Notes:

- In HDR mode, codec/audio selections are constrained to effective renderer behavior (`HEVC` + `Stereo`).
- Title cards are rendered at the resolved output size for both fixed-tier and Smart exports.
- Use the app's `Reset to Plex Defaults` action to apply this profile to an existing installation.

## Known-Good Rollback

Current known-good rollback checkpoint (`Post-ffmpeg HDR`):

- `checkpoint/20260305-known-good-post-ffmpeg-hdr`

Pre-FFmpeg-pivot rollback checkpoint:

- `checkpoint/20260304-known-good-pre-ffmpeg-pivot`

Rollback commands for current known-good:

```bash
git fetch --tags
git checkout checkpoint/20260305-known-good-post-ffmpeg-hdr
git checkout -b codex/recover-known-good
```

## Test

```bash
swift test
```

## Run

```bash
swift run MonthlyVideoGeneratorApp
```
