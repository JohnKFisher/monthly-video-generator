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
- Refine progress UX with ETA prediction and stronger cancellation affordances for long HDR jobs.

Operational updates after first packaged run:
- Added repeatable `.app` bundling script so each build produces a Finder app bundle.
- Added visible app version/build label in the main window.
- Patched still-image rendering path to decode and rasterize source images once before frame emission to reduce provider-related crash risk.
- Hotfix: title card generation now runs on the main actor with a fallback solid-card path to prevent immediate export failure when title card rasterization fails.
- Hotfix: render and UI error handling now includes detailed domain/code/reason/underlying errors and source clip context instead of generic operation failures.
- Hotfix: still/title clip duration handling now aligns written clip end time and clamps insertion to actual track durations to prevent `AVFoundationErrorDomain -11800` insertion failures.
- Hotfix: composition insertion now uses source track timeRange starts (not assumed zero), preventing range mismatch on generated title clips.
- Added failure diagnostics hooks that write a detailed export log file (clip metadata, time ranges, insertion attempts, NSError userInfo) and include that file path in UI error output.
- Hotfix: generated still/title intermediate clips now prefer ProRes 422 for large frame sizes, with runtime codec compatibility probing/fallback, to avoid invalid high-resolution intermediates causing insertion failures.
- Added a regression test that generates a 5712x4284 still-image clip and verifies composition track insertion succeeds.
- Hotfix: render input clips now retain their backing `AVAsset` objects through composition insertion, preventing index-0 `AVFoundationErrorDomain -11800` (`NSOSStatus -12780`) caused by invalidated track references.
- Added opening-title text input in the Style panel so title card text can be set explicitly for each render.
- Hotfix: title-card fallback rendering now draws title text (instead of a blank card) when AppKit title rasterization fails.
- Hotfix: renderer now applies explicit output color metadata based on export dynamic range (SDR=BT.709, HDR=BT.2020 HLG) instead of leaving dynamic-range choice advisory only.
- Added full HDR re-grade/tone-map pass after composition export so HDR output applies explicit per-frame tone mapping instead of metadata-only signaling.
- Added persistent style/export preferences in app settings so title/crossfade/still-duration and export controls restore between launches.
- Improved progress reporting so the UI progress bar now advances across materialization, composition/export, and HDR tone-map phases instead of jumping only at start/end.
- Hotfix: HDR tone-map pass now fails with explicit timeout/status errors when writer input stalls, preventing indefinite “hang” behavior.
- Hotfix: HDR tone-map pass now interleaves audio sample appends while video frames are written, reducing writer backpressure stalls that previously timed out mid-pass.
- Hotfix: HDR tone-map pass now uses a standards-based identity 10-bit pipeline (HLG/BT.2020) with explicit HDR metadata insertion policy instead of a creative filter stack that caused severe clipping/saturation artifacts.
- Hotfix: HDR writer settings now enforce HEVC Main10 with explicit metadata policy (Auto + recompute), and fall back to HLG static signaling (`metadata insertion = None`) when encoder support is limited.
- Added render-complete success alert and an explicit “Open Render Folder” action in the UI for faster post-export discovery.
- Hotfix: HDR pass now resolves per-frame source color tags (HLG/PQ/P3/709) instead of forcing HLG interpretation for every frame, and still-photo intermediates are now tagged from per-image source color space (P3 or BT.709) rather than one fixed BT.709 path.
- Hotfix: HDR photo stills now use gain-map-aware decoding (when present) and are emitted as 10-bit BT.2020 HLG intermediates; non-HDR stills retain source-aware SDR tagging (P3/BT.709).
- Added export option `Write diagnostics log (.log)` so diagnostics generation is explicitly user-controlled; when enabled, successful renders now produce a `.log` and run-report JSON includes the diagnostics path.

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
- 2026-03-04: Added contextual renderer error wrapping and UI-expanded error diagnostics after user-reported generic `The operation could not be completed`.
- 2026-03-04: Fixed title/still clip duration mismatch risk by ending writer sessions at target duration and clamping composition insertion ranges to loaded track durations.
- 2026-03-04: Fixed composition insertion to respect source track start offsets for video/audio tracks.
- 2026-03-04: Added persistent diagnostics file generation on export failure for rapid root-cause analysis.
- 2026-03-04: Switched large-dimension intermediate still/title encoding strategy to ProRes 422 first (with codec compatibility probing/fallback) after diagnostics showed immediate insertion failure on generated 5712x4284 clips.
- 2026-03-04: Added a regression test for large-dimension still clip generation and composition insertion to keep `-12780` failures from regressing silently.
- 2026-03-04: Added strong lifetime retention for source `AVAsset` instances inside render input clips so AVFoundation track insertion operates on valid backing assets.
- 2026-03-04: Added explicit opening-title text input with non-empty fallback behavior when the field is blank.
- 2026-03-04: Updated title-card fallback image generation to render readable title text rather than a blank screen.
- 2026-03-04: Made dynamic-range selection operational by mapping SDR/HDR profile choice to concrete video composition color properties during export.
- 2026-03-04: Implemented two-pass HDR export path with explicit per-frame tone mapping and HDR Main10 re-encode for stronger perceptual HDR output.
- 2026-03-04: Persisted style and export option selections to local defaults so frequent controls retain prior values across app relaunches.
- 2026-03-04: Added phase-aware render progress callbacks and UI progress mapping so progress remains useful throughout long exports.
- 2026-03-04: Added bounded writer-readiness waits in HDR tone mapping so stalled encoder states produce clear failures instead of unbounded waits.
- 2026-03-04: Changed HDR tone-map writer flow to drain audio incrementally during video encoding and in bounded bursts during finalization to avoid muxer starvation stalls.
- 2026-03-04: Replaced creative HDR filter grading with identity color-managed processing in a 10-bit x420 reader/writer path to preserve iPhone HDR appearance.
- 2026-03-04: Adopted explicit VideoToolbox HDR metadata policy settings (`HDRMetadataInsertionMode`, `PreserveDynamicHDRMetadata`) with diagnostics and safe fallback behavior.

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
- 2026-03-04: Added detailed error surfacing in UI and render pipeline for actionable debugging.
- 2026-03-04: Fixed potential first-segment title insertion failure by tightening clip duration math and insertion range selection.
- 2026-03-04: Fixed title-card insertion to use track-native time range starts during composition.
- 2026-03-04: Added per-run failure diagnostics hooks and surfaced diagnostics log path in export error messages.
- 2026-03-04: Updated still/title intermediate codec selection to ProRes 422-first with compatibility probing for large dimensions.
- 2026-03-04: Added `StillImageClipFactoryTests.testLargeStillClipCanBeInsertedIntoCompositionTrack` to lock in large-frame insertion behavior.
- 2026-03-04: Added render-path asset retention hotfix for generated and source clips to prevent `-12780` insertion failures at index 0.
- 2026-03-04: Added opening-title text field to UI/view-model wiring and used it in style generation with a month/year fallback when blank.
- 2026-03-04: Updated fallback title-card renderer to include title text so title clips remain visible even after rasterization fallback.
- 2026-03-04: Enforced explicit output color metadata mapping for SDR/HDR in render export and added regression tests for color-profile mapping.
- 2026-03-04: Added full HDR tone-mapping render pass (reader/writer regrade after composition export) and tests that lock in HDR-pass gating behavior.
- 2026-03-04: Added `UserDefaults` persistence for style/export selections (opening title toggle/text, crossfade, still duration, container/codec/resolution/dynamic range/audio layout/bitrate mode).
- 2026-03-04: Wired determinate progress updates end-to-end (materialization, insertion/export polling, HDR tone mapping) and surfaced percent status text in the app UI.
- 2026-03-04: Hardened HDR tone-map writer readiness waits with timeout + writer-status checks to prevent apparent hangs on problematic exports.
- 2026-03-04: Updated HDR tone-map audio handling to append ready audio samples during frame rendering and complete remaining audio in bounded bursts to prevent writer backpressure deadlocks.
- 2026-03-04: Updated HDR writer configuration to HEVC Main10 + BT.2020 HLG metadata policy, removed creative tone-curve adjustments, and rendered HDR pass in 10-bit x420 buffers.
- 2026-03-04: Added HDR writer-settings regression tests that verify Main10 profile, metadata insertion mode, and dynamic metadata regeneration policy.
- 2026-03-04: Added completion alert and output-folder quick-open control for post-render UX clarity.
- 2026-03-04: Added source-color-space-aware HDR conversion plus per-image still/photo intermediate color tagging (P3/BT.709) while keeping title cards BT.709 for predictable synthetic graphics output.
- 2026-03-04: Added Smart HDR still-photo recovery path that applies ImageIO/CoreImage HDR gain maps and writes 10-bit HLG/BT.2020 still intermediates for HDR exports.
- 2026-03-04: Added `StillImageClipFactoryTests.testLargeStillClipHDRModeCanBeInsertedIntoCompositionTrack` to lock in HDR-mode still intermediate insertion behavior.
- 2026-03-04: Added diagnostics-log toggle in export settings and propagated diagnostics log path through render results into run-report JSON sidecars.

## Risks/Blockers

- Current renderer uses AVFoundation APIs that are deprecated on macOS 15+; functional now, but should be migrated.
- Progress reporting is phase-based and monotonic but still ETA-free (not frame-accurate completion-time prediction).
- Very large photo months may have long materialization times; additional user-facing progress granularity is still needed.
- HDR exports now use an additional full-frame regrade pass and can take materially longer than SDR exports, especially at large resolutions.

## Next Actions (Top 3)

1. Complete S4 by wiring deeper export controls to encode behavior and migrating deprecations.
2. Add ETA-oriented progress forecasting and stronger cancellation UX.
3. Add integration tests and smoke samples for mixed-orientation clips and larger photo month datasets.

## Last Updated

2026-03-04 15:39 America/New_York by Codex
