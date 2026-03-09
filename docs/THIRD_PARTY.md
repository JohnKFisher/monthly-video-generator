# Third-Party Components

## FFmpeg Bundle

This project supports an optional bundled FFmpeg toolchain for HDR exports.

- Location in repo: `third_party/ffmpeg/bin/ffmpeg` and `third_party/ffmpeg/bin/ffprobe`
- Location in packaged app: `Monthly Video Generator.app/Contents/Resources/FFmpeg/`

### Acquisition

Use the fetch helper and provide a version-pinned archive URL + SHA256:

```bash
FFMPEG_BUNDLE_URL="https://example.com/ffmpeg-arm64-gpl.zip" \
FFMPEG_BUNDLE_SHA256="<sha256>" \
./scripts/fetch_ffmpeg_bundle.sh
```

The script verifies SHA256 before installing binaries.

### Licensing

Bundled binaries may include GPL components depending on the selected distribution.
Validate your chosen distribution's licensing terms before redistribution.

### Provenance

After fetch, provenance metadata is recorded at:

- `third_party/ffmpeg/PROVENANCE.txt`
