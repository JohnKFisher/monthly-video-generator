# Third-Party Components

## FFmpeg Bundle

This project ships a bundled FFmpeg toolchain for HDR exports.

- Location in repo: `third_party/ffmpeg/darwin-arm64/` and `third_party/ffmpeg/darwin-x64/`
- Location in packaged app: `Monthly Video Generator.app/Contents/Resources/FFmpeg/`

### Acquisition

The current committed bundle stores separate macOS arm64 and x64 slices from
OSXExperts static macOS builds. The arm64 slice is FFmpeg/FFprobe `8.1`, and
the x64 slice is FFmpeg/FFprobe `8.0`. Packaging assembles the requested app
architectures into `Contents/Resources/FFmpeg/ffmpeg` and
`Contents/Resources/FFmpeg/ffprobe`.
`scripts/build_app.sh` treats the bundle as required and fails before packaging
if either tool is missing, not executable, not launchable, or missing one of the
requested app architectures.

To refresh the bundle, download pinned arm64 and x64 `ffmpeg`/`ffprobe` slices,
verify their checksums, replace the matching files under `third_party/ffmpeg/`,
and update `third_party/ffmpeg/PROVENANCE.txt`.

The older fetch helper can still install a local single-architecture bundle
under ignored `third_party/ffmpeg/bin/` when you provide a version-pinned
archive URL + SHA256:

```bash
FFMPEG_BUNDLE_URL="https://example.com/ffmpeg-arm64-gpl.zip" \
FFMPEG_BUNDLE_SHA256="<sha256>" \
./scripts/fetch_ffmpeg_bundle.sh
```

The script verifies SHA256 before installing binaries, but it does not update the
committed slices used by normal release packaging.

### Licensing

Bundled binaries may include GPL components depending on the selected distribution.
Validate your chosen distribution's licensing terms before redistribution.

### Provenance

Provenance metadata is recorded at:

- `third_party/ffmpeg/PROVENANCE.txt`
