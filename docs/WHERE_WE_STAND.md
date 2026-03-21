# Monthly Video Generator

Current version/build:
- `1.1.0`
- Latest packaged local build verified in this repo: `202`

Current overall status:
- The app is usable now for local folder-based and Apple Photos-based monthly video exports, and this `1.1.0` release folds the approved collage-title exploration back into the shipping app.
- Opening title cards now randomize per export job across the corrected `21`-variant collage-family set, including queued exports and full-year runs.
- Fresh/reset defaults now use a `10.0s` opening title card, and packaged app build numbers continue to use the repo-tracked counted `BUILD_NUMBER` sequence.

What is working now:
- Local-only macOS app workflow with no telemetry or cloud requirement.
- Folder source rendering for mixed photos and videos.
- Apple Photos rendering using month/year filtering and album selection.
- Hidden serial render queue, including year-scan queue creation for non-empty Photos months.
- Opening title cards, capture-date overlays, and crossfades.
- Shipping randomized collage-family opening titles with `21` approved variants.
- Deterministic collage preview selection that fills up to `10` visible photo slots and only repeats images when the source batch is too small.
- Safe output naming, JSON run reports, and optional diagnostics logs.
- FFmpeg-based final exports with bundled FFmpeg support.
- HDR `HEVC` output for the current Plex/Infuse/Apple TV 4K workflow.
- Embedded MP4 metadata and named chapters for the `Family Videos` workflow.
- Stable still-image handling through Apple/AVFoundation materialized intermediate clips.
- HDR still-photo gain-map decoding that respects source-image orientation for affected rotated/oriented HDR photos.

What is partially implemented:
- Stage 4 export controls are in place, but some advanced choices are still constrained by renderer/backend reality.
- Progress reporting exists and is materially better than before, but the longest HDR jobs still need a more polished ETA/cancellation experience.
- Resumable HDR execution exists for large jobs, but the UX around recovery remains technical.

What is not implemented yet:
- Final S4 completion and sign-off.
- Migration away from older AVFoundation export APIs where newer non-deprecated options are preferred.
- A newer still-image fast path that is both faster and trustworthy enough to replace the stable materialized-clip path on `main`.
- A user-facing selector or favorites system for opening-title treatments.

Known limitations and trust warnings:
- The stable still-image path is intentionally conservative and can be slow because it materializes stills into intermediate `.mov` clips before final assembly.
- Large HDR `HEVC` exports can take a long time and use substantial CPU, memory, disk, and temporary storage.
- Apple Photos exports depend on Photos permissions and can be affected by PhotoKit/iCloud materialization latency.
- Balanced bitrate is workable now, but very large 4K60 HDR outputs may still need more tuning for size.
- The chosen randomized opening-title treatment is recorded in the JSON run report, not surfaced in the main UI yet.

Setup/runtime requirements:
- macOS 15-class environment for the current SwiftPM/app workflow.
- Local FFmpeg bundle packaged into the app for the preferred export path.
- Photos permission for Apple Photos exports.
- Enough free disk space for temporary intermediates and final exports.

Important operational risks:
- Interrupting a long HDR export can leave behind temporary or resumable artifacts until cleanup runs.
- Photos-backed exports may spend significant time preparing media before visible output appears.
- The app is safest when treated as local-only and single-user; it is not designed around shared/networked coordination.

Recommended next priorities:
- Manually smoke-test several real exports and confirm the randomized collage-family openers stay readable and free of hollow photo-box artifacts.
- Re-tune export defaults and bitrate targets using real-world 4K60 HDR examples.
- Improve progress/cancel/resume UX for long-running FFmpeg/HDR jobs.
- Add a lightweight inspectable UI hint or export-summary note for which title treatment was chosen, if that would help review iteration.

Most recent durable known-good anchor:
- `known-good/20260320-v1-1-0-collage-titles`
