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
- PhotoKit source selection now supports both month/year filtering and album-based filtering.
- Export UI/model for container/codec/frame rate/resolution/HDR/audio layout/bitrate mode.
- Plex/Infuse-oriented default export preset for Apple TV 4K (`MP4 + HEVC + HDR + Smart Audio + Balanced + HDR Auto + HDR HEVC Encoder Default`), plus explicit UI reset action.
- Temporary test-only output naming and mega-test batch UI for exercising Resolution/FPS/Range/Audio combinations.

Open for S4 completion:
- Migrate renderer to newer non-deprecated AVFoundation export APIs.
- Continue tightening renderer-option parity where settings remain advisory outside HDR constraints.
- Refine progress UX with ETA prediction and stronger cancellation affordances for long HDR jobs.
- Before finalizing export defaults, validate representative `4K60 / HEVC / Balanced` output sizes for the Plex -> Infuse -> Apple TV 4K workflow and reduce the balanced target if files are unreasonably large.

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
- Expanded the single-render completion alert so it now summarizes the requested and actual export settings used for that finished file, including Smart/Auto resolutions such as `Smart (5.1)` and `Auto (Bundled)`.
- Hotfix: HDR pass now resolves per-frame source color tags (HLG/PQ/P3/709) instead of forcing HLG interpretation for every frame, and still-photo intermediates are now tagged from per-image source color space (P3 or BT.709) rather than one fixed BT.709 path.
- Hotfix: HDR photo stills now use gain-map-aware decoding (when present) and are emitted as 10-bit BT.2020 HLG intermediates; non-HDR stills retain source-aware SDR tagging (P3/BT.709).
- Added export option `Write diagnostics log (.log)` so diagnostics generation is explicitly user-controlled; when enabled, successful renders now produce a `.log` and run-report JSON includes the diagnostics path.
- Pivoted final export backend to capability-gated FFmpeg rendering (zscale + xfade + acrossfade + codec-aware encoder selection), with HDR on Main10 HEVC and SDR now also using FFmpeg instead of `AVAssetExportSession`.
- Hotfix: SDR FFmpeg exports that include HDR source videos now apply targeted HDR-to-SDR tone mapping before BT.709 conversion, and HLG source videos use an HLG-tuned nominal-peak/gamut-reduction path to avoid still-blown-out iPhone highlights.
- Added FFmpeg engine selection UI (`Auto/System/Bundled`) and persisted this preference with existing style/export settings.
- Added FFmpeg binary acquisition + bundling workflow (`scripts/fetch_ffmpeg_bundle.sh`, `scripts/build_app.sh`) with checksum verification and provenance file.
- Added a known-good pre-pivot checkpoint tag for deterministic rollback: `checkpoint/20260304-known-good-pre-ffmpeg-pivot`.
- Hotfix: FFmpeg HDR filter graph now avoids float RGB (`gbrpf32le`) intermediates to reduce high-resolution memory pressure and signal-9 failure risk; FFmpeg termination diagnostics now report signal-vs-exit and prioritize actionable stderr lines.
- Hotfix: HDR exports using `Match Source Max` now cap FFmpeg render size to 4K-equivalent bounds (landscape max `3840x2160`, portrait max `2160x3840`) to reduce SIGKILL failures on very large source dimensions.
- Hotfix: FFmpeg render completion wait now uses a race-free termination poll path so fast process exits cannot deadlock the export task at partial progress (for example, frozen around 31%).
- Hotfix: FFmpeg command now sets `-stats_period 0.5` with `-progress pipe:2` so HDR progress updates continue during long encodes instead of appearing stuck at early percentages.
- Hotfix: diagnostics log files are now preallocated at render start (when enabled) and finalized to the same path on success/failure so a log file is visible during long renders.
- Hotfix: FFmpeg progress callbacks are now decoupled from diagnostics lock contention so verbose stderr logging cannot starve UI progress updates.
- Hotfix: FFmpeg stdout/stderr pipes are explicitly closed after process termination so async line readers cannot block render completion after a successful encode.
- Hotfix: FFmpeg HDR renderer now includes a no-progress stall watchdog (timeline + output-file-growth) that terminates hung encodes with explicit diagnostics instead of hanging indefinitely.
- Improved render-status UX by adding live FFmpeg HDR status details (elapsed time, output size, encode speed) and surfacing phase-specific status text through coordinator/engine/UI callbacks.
- Hotfix: FFmpeg HDR progress now includes fallback advancement from output-file growth and periodic heartbeat status updates so long encodes no longer appear frozen when `out_time` lags.
- Hotfix: FFmpeg HDR stall detection now treats rising child-process CPU time as activity, avoiding false kills when encoders are still busy but not emitting `out_time` updates.
- Hotfix: FFmpeg HDR watchdog escalation now attempts graceful shutdown first (`SIGINT`, then `SIGTERM`) before using `SIGKILL` as a last resort.
- Hotfix: FFmpeg HDR progress now routes through stderr (`-progress pipe:2`) with explicit progress-line parsing, preventing stdout progress pipe backpressure from stalling long encodes.
- Hotfix: FFmpeg HDR command now includes `-nostdin` and removes x265 `hdr-opt=1` for HLG output to avoid non-actionable HDR10-opt warnings during failure triage.
- Hotfix: FFmpeg HDR command now adds `-ignore_unknown` and `-dn` to reduce failure risk from unsupported APAC/data side streams in iPhone QuickTime sources.
- Hotfix: FFmpeg stdout/stderr consumption now uses byte-level CR/LF parsing instead of `bytes.lines`, improving pipe-drain reliability when FFmpeg emits carriage-return delimited output.
- Hotfix: FFmpeg watchdog now uses an extended late-stage no-progress timeout once combined progress reaches >=95%, avoiding premature hard-kill near completion/finalization.
- Hotfix: FFmpeg pipe readers now run on a dedicated utility queue using blocking `availableData` reads to keep stderr/stdout draining in real time during long HDR encodes.
- Established new known-good rollback checkpoint (`Post-ffmpeg HDR`): `checkpoint/20260305-known-good-post-ffmpeg-hdr`.
- Updated defaults workflow for Plex + Infuse + Apple TV 4K: fresh installs now default to HDR MP4/HEVC profile, existing saved preferences remain untouched, and Export UI includes `Reset to Plex Defaults`.
- Updated Export profile manager to resolve effective HDR settings (`HEVC`) with explicit compatibility messaging so UI/behavior stay aligned.
- Replaced fixed `30 fps` export with `30 fps` / `60 fps` / `Smart` controls, made Smart the default, and resolved Smart to `60 fps` only when any selected video is `>= 50 fps`.
- Added Apple Photos Smart-fps inspection before render prep, including progress/status messaging, cached AVAsset reuse during later materialization, and cancellation-aware PhotoKit request handling.
- Added a temporary auto-generated testing output name (`Testing - S2026E<epoch> - <Resolution> - <FPS>fps - <Range> - <Audio>`) that stays synced until manually edited.
- Added a temporary `Mega Test` batch mode that expands checked Resolution/FPS/Range/Audio axes into sequential renders while reusing one preparation pass and prompting after per-combination failures.
- Switched SDR final export from `AVAssetExportSession` to the shared FFmpeg backend, added SDR H.264/HEVC encoder capability probing, and normalized SDR outputs to BT.709 with real bitrate control.
- Reworked the main window into a denser two-column layout with a vertical scroll fallback so all controls remain reachable on smaller window heights.
- Added an `HDR HEVC Encoder` picker with `Default` and strict `VideoToolbox` modes, threaded that selection through FFmpeg capability resolution and completion summaries, and kept `Default` as the persisted Plex/Infuse baseline.
- Mega Test now forces `VideoToolbox` for HDR HEVC combinations at execution time so large HDR test batches run faster without mutating the user’s saved single-render encoder choice.

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
- 2026-03-04: Approved quality-first HDR pivot to FFmpeg with capability gate (`zscale`, `xfade`, `acrossfade`, HEVC Main10), preferring system ffmpeg then bundled fallback.
- 2026-03-04: Added bundled FFmpeg acquisition policy (arm64, GPL-capable binary permitted) with SHA256 verification and explicit provenance logging.
- 2026-03-04: Established rollback anchor tag `checkpoint/20260304-known-good-pre-ffmpeg-pivot` before FFmpeg HDR backend implementation.
- 2026-03-05: Promoted the latest stable HDR/FFmpeg fixes as the new known-good rollback checkpoint `checkpoint/20260305-known-good-post-ffmpeg-hdr` (`Post-ffmpeg HDR`).
- 2026-03-05: Approved defaults-first export policy for Plex + Infuse + Apple TV 4K with HDR as the default dynamic range and manual reset action for existing installations.
- 2026-03-05: Expanded Photos input scope to support explicit album selection while preserving existing month/year filtering mode.
- 2026-03-05: Approved Smart fps export policy with `30 fps` / `60 fps` / `Smart`, defaulting to `Smart` and promoting to `60 fps` only when any selected video is `>= 50 fps`.
- 2026-03-05: Approved temporary testing-only output naming plus a removable mega-test batch UI for Resolution/FPS/Range/Audio matrix exports.
- 2026-03-06: Approved moving SDR final export onto the shared FFmpeg backend while keeping AVFoundation for discovery and still/title intermediate generation.
- 2026-03-06: Approved a space-efficiency UI pass so the full control set remains visible without vertically clipping the window.

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
- 2026-03-04: Added FFmpeg HDR pipeline modules (`FFmpegCapabilityProbe`, `FFmpegBinaryResolver`, `FFmpegCommandBuilder`, `FFmpegHDRRenderer`) and routed HDR exports through capability-gated FFmpeg backend.
- 2026-03-04: Added HDR engine preference to `ExportProfile` and UI (`Auto/System/Bundled`) with persistence across launches.
- 2026-03-04: Added HDR backend summary propagation into UI status and run-report JSON.
- 2026-03-04: Added FFmpeg acquisition/bundling scripts and third-party licensing/provenance documentation.
- 2026-03-04: Added FFmpeg pipeline unit tests for capability parsing, resolver fallback, command generation, and profile codable persistence.
- 2026-03-04: Removed float RGB intermediate conversion (`gbrpf32le`) from FFmpeg HDR clip normalization path to reduce memory pressure on large `matchSourceMax` exports.
- 2026-03-04: Improved FFmpeg HDR failure surfacing to include termination reason (`exit` vs `signal`) and stronger stderr detail selection.
- 2026-03-04: Added FFmpeg HDR `matchSourceMax` safety cap to 4K-equivalent bounds and surfaced this as an export compatibility warning.
- 2026-03-05: Replaced FFmpeg termination-handler wait with a race-free async poll and added parser coverage for both `out_time_ms` and `out_time_us` progress keys.
- 2026-03-05: Enabled periodic FFmpeg progress emission (`-stats_period 0.5`) and preallocated diagnostics log file paths at render start for improved long-run observability.
- 2026-03-05: Removed shared callback lock coupling between FFmpeg diagnostics and progress paths so progress updates remain responsive under heavy stderr logging.
- 2026-03-05: Force-closed FFmpeg output/error pipes after process termination to prevent post-encode completion hangs while awaiting stream readers.
- 2026-03-05: Added an FFmpeg HDR stall watchdog that monitors both `out_time` advancement and output-file byte growth, terminating stuck processes with explicit stall context.
- 2026-03-05: Added phase/status callback plumbing from renderer to UI and upgraded on-screen render status with HDR encode elapsed/output-size/speed details.
- 2026-03-05: Added FFmpeg HDR progress fallback based on estimated output-size growth plus periodic status heartbeats to keep UI progress moving during long startup/encode phases.
- 2026-03-05: Updated FFmpeg stall detection to include child-process CPU-time activity and changed watchdog shutdown to graceful interrupt/terminate before hard kill.
- 2026-03-05: Updated FFmpeg filtergraph audio selectors to explicit first-stream syntax (`a:0`) for better compatibility with multi-audio iPhone source files.
- 2026-03-05: Moved FFmpeg progress stream to stderr (`pipe:2`) and parse/suppress progress key lines in stderr consumption to keep progress live without pipe-fill stalls.
- 2026-03-05: Added `-nostdin` to FFmpeg HDR commands and removed x265 `hdr-opt=1` from HLG path to reduce misleading HDR10-opt warnings.
- 2026-03-05: Added FFmpeg `-ignore_unknown` and `-dn` flags for HDR renders so unsupported APAC/data side streams do not participate in stream selection/probing logic.
- 2026-03-05: Replaced FFmpeg pipe `bytes.lines` readers with byte-level CR/LF parsing to keep stream draining robust under mixed carriage-return/newline output.
- 2026-03-05: Changed stall watchdog to use a longer late-stage timeout (>=95% progress) before escalation, reducing false positives near encode finalization.
- 2026-03-05: Moved FFmpeg stdout/stderr reads to a dedicated background queue (`availableData`) after diagnostics showed stream lines were still being delivered only at process teardown.
- 2026-03-05: Added `ExportProfile.plexInfuseAppleTV4KDefault`, switched manager defaults to this profile, and introduced profile-resolution hooks that enforce effective HDR codec behavior.
- 2026-03-05: Updated Export UI/view-model defaults and added `Reset to Plex Defaults`; HDR mode now locks codec selection to effective renderer constraints with explanatory copy.
- 2026-03-05: Added regression tests for new default profile values, manager default resolution, HDR profile normalization behavior, and codable round-trip of the new preset.
- 2026-03-05: Replaced `Match Source Max` with `Smart`/`720p`/`1080p`/`4K` resolution choices, normalized legacy saved `matchSourceMax` settings to `smart`, and made Smart the new default export resolution.
- 2026-03-05: Added shared 16:9 Smart resolution sizing, applied aspect-fit video transforms with black background bars on the SDR AVFoundation path, and locked title cards to the final resolved output size.
- 2026-03-05: Added Photos filter-mode controls (`Month/Year` or `Album`) in the Input panel, plus album refresh/loading state handling in the view model.
- 2026-03-05: Added PhotoKit album discovery/render support and new `PhotosScope.album` model path with run-report-friendly source description.
- 2026-03-05: Added `FrameRatePolicy` (`30 fps` / `60 fps` / `Smart`) to export profile/UI/persistence, made Smart the default, and applied the resolved output fps to SDR composition timing, HDR FFmpeg planning, and still/title intermediate clip generation.
- 2026-03-05: Added Smart-fps Photos inspection with AVAsset URL/fps caching so Smart decisions can inspect/download selected iCloud-backed videos once and later reuse the same materialized asset during render.
- 2026-03-05: Upgraded render cancellation so the top-level render task cancellation also stops Smart-fps Photos inspection and cancels outstanding PhotoKit requests.
- 2026-03-05: Added regression tests for Smart-fps resolution logic, 60 fps still/title intermediate generation, folder-discovered source frame rates, and Photos Smart-fps cache reuse/cancellation behavior.
- 2026-03-05: Added temporary app-layer testing helpers for generated output names and mega-test matrix expansion, keeping the test-only logic isolated from the render engine.
- 2026-03-05: Added Output name auto-sync/unlock behavior plus a `Mega Test` UI section that can batch sequential Resolution/FPS/Range/Audio renders and prompt to continue or stop after failures.
- 2026-03-05: Added app-level tests for temporary output naming behavior, mega-test preparation reuse, manual-name bypass during batches, and stop/continue failure handling.
- 2026-03-06: Added SDR FFmpeg HDR-source tone mapping with capability-gated `tonemap` filter requirements, bundled-binary fallback when system FFmpeg lacks tone-map support, and regression tests for PQ/HLG SDR conversion paths.
- 2026-03-06: Retuned the SDR HLG source-video conversion path to `HLG -> linear:npl=1400 -> BT.709 primaries -> mobius tonemap -> BT.709/range=tv` after sample-frame comparisons showed the earlier `npl=400` recipe still left iPhone faces and highlights too hot in SDR exports.
- 2026-03-06: Replaced SDR `AVAssetExportSession` final export with the shared FFmpeg backend, generalized FFmpeg capability probing for SDR H.264/HEVC encoders, and updated command generation to emit BT.709-tagged SDR or BT.2020 HLG HDR outputs from the same pipeline.
- 2026-03-06: Updated Export UI/copy and compatibility warnings so bitrate and engine messaging reflect unified FFmpeg final export behavior instead of HDR-only wording.
- 2026-03-06: Added SDR FFmpeg command coverage in unit tests and removed active use of deprecated `AVAssetExportSession` APIs from the SDR final export path.
- 2026-03-06: Reorganized the main window into responsive two-column and one-column layouts, compacted the densest control rows, and wrapped the content in a scroll view so no options are lost on shorter windows.
- 2026-03-06: Added a script-generated macOS app icon pipeline (`scripts/generate_app_icon.swift` -> `.iconset` -> `AppIcon.icns` via `iconutil`), embedded the custom icon in built app bundles, and bumped the shipped app version to `0.4.0`.
- 2026-03-06: Expanded audio layout controls to `Mono` / `Stereo` / `5.1` / `Smart`, made Smart the new default, and resolved Smart audio from inspected source-video channel counts with a conservative `5.1` fallback for uninspectable videos.
- 2026-03-06: Added an `Audio` Mega Test axis plus `- <Audio>` testing filename tokens, keeping generated names synced with the selected audio policy while Mega Test varies audio combinations deterministically.
- 2026-03-06: Updated the FFmpeg render plan/command builder to emit real mono/stereo/5.1 AAC outputs instead of hard-coded stereo, including layout-matched silent fillers, final `-ac`, and bitrate-aware output size estimates.

## Risks/Blockers

- Final SDR/HDR export now runs on FFmpeg, but still/title intermediate generation and some legacy helper code still rely on AVFoundation/VideoToolbox.
- Progress reporting is phase-based and monotonic but still ETA-free (not frame-accurate completion-time prediction).
- Very large photo months may have long materialization times; additional user-facing progress granularity is still needed.
- FFmpeg-backed final exports can take materially longer than the old SDR preset path, especially at `4K60` or when software encoders (`libx264`/`libx265`) are selected by capability fallback.
- FFmpeg bundling is operator-managed; missing/invalid bundled binaries will fail exports in `Bundled Only` mode.

## Next Actions (Top 3)

1. Run manual SDR/HDR visual validation on mixed iPhone SDR/HDR months and tune FFmpeg SDR tone/compression defaults if needed.
2. Add integration smoke tests that execute the unified FFmpeg final-export path with fixture clips and verify metadata tags.
3. Decide whether to rename the legacy `hdrFFmpegBinaryMode`/`FFmpegHDRRenderer` symbols now that they serve both SDR and HDR.

## Rollback Procedure

To return to the current known-good rollback (`Post-ffmpeg HDR`):

1. `git fetch --tags`
2. `git checkout checkpoint/20260305-known-good-post-ffmpeg-hdr`
3. Optional working branch from checkpoint: `git checkout -b codex/recover-known-good`

For the pre-FFmpeg-pivot baseline, use:

- `git checkout checkpoint/20260304-known-good-pre-ffmpeg-pivot`

## Last Updated

2026-03-06 00:51 America/New_York by Codex
