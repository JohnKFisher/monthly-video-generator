# Monthly Video Generator

Current version/build:
- `2.1.1`
- Latest checked-in build identity: `212`

Current overall status:
- The app is usable now for local folder-based and Apple Photos-based monthly video exports, and this `2.1.1` release keeps the protected HDR/export path intact while fixing release packaging so bundled FFmpeg/ffprobe are present in clean CI-built DMGs.
- The bundled FFmpeg/ffprobe toolchain is now committed as validated macOS architecture slices, and packaging fails before producing an app if either tool is missing, not launchable, or missing a requested architecture.
- The `2.1.0` GitHub DMG was published without bundled FFmpeg because the local `third_party/ffmpeg/bin` inputs were ignored; use `2.1.1` or later for packaged HDR exports.
- Opening title cards now randomize per export job across the corrected `21`-variant collage-family set, including queued exports and full-year runs.
- Fresh/reset defaults now use a `10.0s` opening title card, and release identity now comes from the checked-in `VERSION` plus `BUILD_NUMBER` files.
- The default Plex/Infuse HDR export now uses the bakeoff-approved `crf21-fast` final `libx265` tuning.

What is working now:
- Local-only macOS app workflow with no telemetry or cloud requirement.
- Folder source rendering for mixed photos and videos.
- Apple Photos rendering using month/year filtering and album selection.
- Apple Photos album rendering can span multiple months; album mode uses the earliest dated item for Plex month/year identity and the album title for auto-managed naming.
- Mac-native shell surfaces for the main workflow, including command menus, keyboard shortcuts, toolbar-owned primary actions, a dedicated Settings window, and a dedicated About window.
- Persisted default output-folder selection with bookmark-based restoration and fallback to the app's Movies folder default when a saved folder disappears.
- Hidden serial render queue, including year-scan queue creation for non-empty Photos months.
- Opening title cards, capture-date overlays, and crossfades.
- Shipping randomized collage-family opening titles with `21` approved variants.
- Deterministic collage preview selection that fills up to `10` visible photo slots and only repeats images when the source batch is too small.
- Safe output naming, JSON run reports, and optional diagnostics logs.
- Audit-only progressive HDR presentation timing rollups now record `title` / `still` / `video` clip counts plus capture-date-overlay state in diagnostics and structured run reports.
- The Status panel now shows richer render liveness details and an always-visible Live Snapshot area that can capture occasional still snapshots from completed/readable render artifacts without attempting live playback.
- FFmpeg-based final exports with required bundled FFmpeg support in packaged builds.
- HDR `HEVC` output for the current Plex/Infuse/Apple TV 4K workflow.
- Default Plex/Infuse HDR exports now ship with the `crf21-fast` final software HEVC tuning that won the local bakeoff review.
- Embedded MP4 metadata and named chapters for the `Family Videos` workflow.
- Stable still-image handling through Apple/AVFoundation materialized intermediate clips.
- HDR still-photo gain-map decoding that respects source-image orientation for affected rotated/oriented HDR photos.
- Shared packaging scripts for `.app` and `.dmg` creation from committed source, including required bundled FFmpeg/ffprobe preflight.
- GitHub Actions build/release workflows that build and publish from committed `VERSION` and `BUILD_NUMBER` changes on `main`.
- Optional About-style repository link plumbing exists in the app, but stays hidden until a repo URL is configured.

What is partially implemented:
- Stage 4 export controls are in place, but some advanced choices are still constrained by renderer/backend reality.
- Progress reporting exists and is materially better than before, including a low-frequency live snapshot inspector, but the longest HDR jobs still need a more polished ETA/cancellation experience.
- Resumable HDR execution exists for large jobs, but the UX around recovery remains technical.
- The window shell is materially more Mac-native now, but it is still a single primary window backed by one large render-oriented view model; more shell/controller splitting remains possible if future work justifies the churn.
- The audit-only progressive presentation timing data is in place, but no still/title fast path earned promotion and the protected export path remains intentionally conservative.

What is not implemented yet:
- Final S4 completion and sign-off.
- Migration away from older AVFoundation export APIs where newer non-deprecated options are preferred.
- A newer still-image fast path that is both faster and trustworthy enough to replace the stable materialized-clip path on `main`.
- A user-facing selector or favorites system for opening-title treatments.

Known limitations and trust warnings:
- The stable still-image path is intentionally conservative and can be slow because it materializes stills into intermediate `.mov` clips before final assembly.
- Large HDR `HEVC` exports can take a long time and use substantial CPU, memory, disk, and temporary storage.
- Apple Photos exports depend on Photos permissions and can be affected by PhotoKit/iCloud materialization latency.
- The new `crf21-fast` HDR default was approved from local bakeoff artifacts, but especially demanding motion-heavy material may still justify future spot checks before pushing compression further.
- The chosen randomized opening-title treatment is recorded in the JSON run report, not surfaced in the main UI yet.
- Packaged builds are ad-hoc signed and not notarized, so downloaded copies may still require Finder `Open` or `System Settings -> Privacy & Security -> Open Anyway`.
- The current bundle identifier remains mixed-case (`com.jkfisher.MonthlyVideoGenerator`) pending a separate migration decision; it was intentionally not renamed during this alignment pass.

Setup/runtime requirements:
- macOS 15-class environment for the current SwiftPM/app workflow.
- Committed macOS FFmpeg/ffprobe slices packaged into the app for the preferred export path.
- Photos permission for Apple Photos exports.
- Enough free disk space for temporary intermediates and final exports.

Important operational risks:
- Interrupting a long HDR export can leave behind temporary or resumable artifacts until cleanup runs.
- Photos-backed exports may spend significant time preparing media before visible output appears.
- Live Snapshot is opportunistic: it waits for completed/readable artifacts and may show a waiting message for long stretches during stages where only active encoder output exists.
- The app is safest when treated as local-only and single-user; it is not designed around shared/networked coordination.

Recommended next priorities:
- Manually smoke-test the new Mac shell: menus, keyboard shortcuts, Settings, About window, output-folder persistence, and the split main-window workflow with real exports.
- Manually smoke-test several real exports and confirm the randomized collage-family openers stay readable and free of hollow photo-box artifacts.
- Spot-check the new `crf21-fast` default on a few real-world 4K60 HDR exports before pushing to even higher compression.
- Improve progress/cancel/resume UX for long-running FFmpeg/HDR jobs.
- Add a lightweight inspectable UI hint or export-summary note for which title treatment was chosen, if that would help review iteration.
- Keep future performance work tightly scoped to output-identical candidates unless a new bakeoff path is explicitly approved again.

Most recent durable known-good anchor:
- `known-good/20260320-v1-1-0-collage-titles`
