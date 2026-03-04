# Monthly Video Generator Living Plan

## Project Summary

Build a desktop-first macOS app (SwiftUI + AVFoundation/PhotoKit, local-only) in four stages:

1. Folder-to-video (images + videos).
2. Crossfades + opening title.
3. Apple Photos month/year source.
4. Advanced export controls (quality/format/HDR/audio layout).

## Stage Matrix

| Stage | Description | Status |
| --- | --- | --- |
| S0 | Bootstrap + living document workflow | Done |
| S1 | Folder to video | Done |
| S2 | Effects (title + crossfades) | Done |
| S3 | Apple Photos integration | Done |
| S4 | Export controls | In Progress |

## Milestone Exit Criteria

- [x] S0 complete: package/app scaffold compiles, README workflow added, living doc template and protocol enforced.
- [x] S1 complete: recursive folder discovery, deterministic ordering, image+video render, source video audio, safe output naming, duration warning.
- [x] S2 complete: opening title card and crossfade transitions with default behavior compatibility.
- [x] S3 complete: read-only PhotoKit flow, month/year local-time filtering, denied/limited permission handling.
- [ ] S4 complete: export control model/UI for codec/container/resolution/HDR/audio layout with compatibility messaging.

## Current Status Snapshot

Core app and pipeline are implemented and verified with `swift build` + `swift test`.

Implemented now:
- Desktop SwiftUI app with folder/photos source selection.
- Recursive folder scan and deterministic ordering.
- Timeline builder with title card + crossfade support.
- AVFoundation render engine for mixed images/videos with source video audio.
- Safe output naming with auto-versioning in selected output directory.
- PhotoKit discovery/materialization for month/year library rendering.
- Export UI/model for container/codec/resolution/HDR/audio layout/bitrate mode.

Open for S4 completion:
- Migrate renderer to newer non-deprecated AVFoundation export APIs.
- Enforce more export-profile options directly in encode settings (currently some are advisory/UI-level compatibility warnings).
- Add richer progress reporting beyond start/finish updates.

Operational updates after first packaged run:
- Added repeatable `.app` bundling script so each build produces a Finder app bundle.
- Added visible app version/build label in the main window.
- Patched still-image rendering path to decode and rasterize source images once before frame emission to reduce provider-related crash risk.
- Hotfix: title card generation now runs on the main actor with a fallback solid-card path to prevent immediate export failure when title card rasterization fails.

## Decisions Log

- 2026-03-03: Desktop app first; native Swift/AVFoundation first; local-only processing.
- 2026-03-03: Stage 1 includes images + videos with full clip duration and source video audio.
- 2026-03-03: Photos filtering uses capture date in local timezone.
- 2026-03-03: Default output naming uses auto-versioning in a default output folder.
- 2026-03-03: Kept zero third-party dependencies through S3.
- 2026-03-04: Standardized app bundling via `scripts/build_app.sh` with `VERSION` file + generated build number.
- 2026-03-04: Surface `CFBundleShortVersionString` and `CFBundleVersion` in UI for runtime traceability.
- 2026-03-04: Switched still image clip creation to ImageIO decode + rasterization path to address crash in CoreGraphics provider reads.
- 2026-03-04: Added title-card creation fallback and main-actor AppKit rendering path after user-reported `Unable to create title card image` runtime failure.

## Changes Since Last Update

- 2026-03-03: Initialized git repository, created baseline commit, and created checkpoint branch with pre-change snapshot commit.
- 2026-03-03: Added Swift package scaffold and desktop app shell (`MonthlyVideoGeneratorApp`).
- 2026-03-03: Implemented core models, discovery, timeline builder, export profile manager, output resolver, and run report service.
- 2026-03-03: Implemented AVFoundation render engine with title card and crossfade composition.
- 2026-03-03: Implemented PhotoKit discovery and asset materialization for read-only month/year workflows.
- 2026-03-03: Added tests for recursive discovery, deterministic ordering, duration warning behavior, output collision naming, and month/year boundaries.
- 2026-03-03: `swift build` and `swift test` passing.
- 2026-03-04: Added `scripts/build_app.sh` to generate `dist/MonthlyVideoGenerator.app` on every build.
- 2026-03-04: Added `VERSION` file and dynamic build number injection into app `Info.plist`.
- 2026-03-04: Added version/build label to main UI.
- 2026-03-04: Reworked still-image rendering to use pre-rasterized CGImage frames for stability.
- 2026-03-04: Added title-card hotfix to avoid export abort on title rasterization failure.

## Risks/Blockers

- Current renderer uses AVFoundation APIs that are deprecated on macOS 15+; functional now, but should be migrated.
- Progress reporting is coarse (start/end) rather than granular throughout export.
- Very large photo months may have long materialization times; additional user-facing progress granularity is still needed.

## Next Actions (Top 3)

1. Complete S4 by wiring deeper export controls to encode behavior and migrating deprecations.
2. Add granular render/materialization progress and stronger cancellation UX.
3. Add integration tests and smoke samples for mixed-orientation clips and larger photo month datasets.

## Last Updated

2026-03-04 08:51 America/New_York by Codex
