# Monthly Video Generator

Current version/build:
- `1.0.3`
- Latest packaged local build verified in this repo: `20260319232500`

Current overall status:
- The app is in active development but usable now for local folder-based and Apple Photos-based slideshow exports.
- `main` is currently back on the stable still-image pipeline after the experimental direct-photo path was rolled back.
- The rolled-back stable path was verified with a full Apple Photos album export of `Testing` on March 19, 2026.

What is working now:
- Local-only macOS app workflow with no telemetry or cloud requirement.
- Folder source rendering for mixed photos and videos.
- Apple Photos rendering using month/year filtering and album selection.
- Opening title card, capture-date overlays, and crossfades.
- Safe output naming and report generation.
- FFmpeg-based final exports with bundled FFmpeg support.
- HDR `HEVC` output for the current Plex/Infuse/Apple TV 4K workflow.
- Embedded MP4 metadata and named chapters for the `Family Videos` workflow.
- Stable still-image handling through Apple/AVFoundation materialized intermediate clips.

What is partially implemented:
- Stage 4 export controls are in place, but the project still treats some advanced choices as constrained by renderer/backend reality.
- Progress reporting exists, but long-running HDR exports are still better than polished rather than fully “done.”
- Resumable HDR execution exists for large jobs, but the UX around it is still technical.

What is not implemented yet:
- Final S4 completion and sign-off.
- Migration away from older AVFoundation export APIs where newer non-deprecated options are preferred.
- A newer still-image fast path that is both faster and trustworthy enough to replace the stable materialized-clip path on `main`.
- Fully polished ETA/cancellation/recovery UX for the heaviest HDR exports.

Known limitations and trust warnings:
- The stable still-image path is intentionally conservative and can be slow because it materializes stills into intermediate `.mov` clips before final assembly.
- Large HDR `HEVC` exports can take a long time and use substantial CPU, memory, disk, and temporary storage.
- Apple Photos exports depend on Photos permissions and can be affected by PhotoKit/iCloud materialization latency.
- Balanced bitrate is workable now, but very large 4K60 HDR outputs may still need more tuning for size.
- Experimental direct-photo still handling was rolled back because it did not hold up as a reliable speed win.

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
- Re-tune export defaults and bitrate targets using real-world 4K60 HDR examples.
- Improve progress/cancel/resume UX for long-running FFmpeg/HDR jobs.
- Replace or redesign the abandoned experimental still-photo fast path only if it can be proven faster without quality or stability regressions.
- Continue reducing places where requested export settings and actual renderer behavior can diverge.

Most recent durable known-good anchor:
- `known-good/20260320-stable-rollback`
