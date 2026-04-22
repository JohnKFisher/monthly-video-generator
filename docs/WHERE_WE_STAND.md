# Monthly Video Generator

Current version/build:
- `1.3.0`
- Latest checked-in build identity: `208`

Current overall status:
- The app is usable now for local folder-based and Apple Photos-based monthly video exports, and this `1.2.0` release is the first intended public GitHub-published cut after the repo cleanup and CI/release alignment work.
- Opening title cards now randomize per export job across the corrected `21`-variant collage-family set, including queued exports and full-year runs.
- Fresh/reset defaults now use a `10.0s` opening title card, and release identity now comes from the checked-in `VERSION` plus `BUILD_NUMBER` files.

What is working now:
- Local-only macOS app workflow with no telemetry or cloud requirement.
- Folder source rendering for mixed photos and videos.
- Apple Photos rendering using month/year filtering and album selection.
- Mac-native shell surfaces for the main workflow, including command menus, keyboard shortcuts, toolbar-owned primary actions, a dedicated Settings window, and a dedicated About window.
- Persisted default output-folder selection with bookmark-based restoration and fallback to the app's Movies folder default when a saved folder disappears.
- Hidden serial render queue, including year-scan queue creation for non-empty Photos months.
- Opening title cards, capture-date overlays, and crossfades.
- Shipping randomized collage-family opening titles with `21` approved variants.
- Deterministic collage preview selection that fills up to `10` visible photo slots and only repeats images when the source batch is too small.
- Safe output naming, JSON run reports, and optional diagnostics logs.
- An explicit in-app `Run HEVC Bakeoff` command that renders the `Test Export` Photos album into a timestamped comparison bundle with `index.html`, `manifest.json`, per-candidate videos, diagnostics, run reports, and extracted still frames for human review.
- FFmpeg-based final exports with bundled FFmpeg support.
- HDR `HEVC` output for the current Plex/Infuse/Apple TV 4K workflow.
- Embedded MP4 metadata and named chapters for the `Family Videos` workflow.
- Stable still-image handling through Apple/AVFoundation materialized intermediate clips.
- HDR still-photo gain-map decoding that respects source-image orientation for affected rotated/oriented HDR photos.
- Shared packaging scripts for `.app` and `.dmg` creation from committed source.
- First-pass GitHub Actions build/release workflows checked in for the repo's first public GitHub initialization.
- Optional About-style repository link plumbing exists in the app, but stays hidden until a repo URL is configured.

What is partially implemented:
- Stage 4 export controls are in place, but some advanced choices are still constrained by renderer/backend reality.
- Progress reporting exists and is materially better than before, but the longest HDR jobs still need a more polished ETA/cancellation experience.
- Resumable HDR execution exists for large jobs, but the UX around recovery remains technical.
- The new bakeoff flow exists in the app, but it still depends on Photos authorization being granted to the app process and on manual review of the generated comparison bundle afterward.
- The window shell is materially more Mac-native now, but it is still a single primary window backed by one large render-oriented view model; more shell/controller splitting remains possible if future work justifies the churn.
- The public GitHub repository and release automation are in place, but the first remote release run exposed a GitHub runner toolchain mismatch and still needs a clean passing rerun on `macos-15`.

What is not implemented yet:
- Final S4 completion and sign-off.
- Migration away from older AVFoundation export APIs where newer non-deprecated options are preferred.
- A newer still-image fast path that is both faster and trustworthy enough to replace the stable materialized-clip path on `main`.
- A user-facing selector or favorites system for opening-title treatments.

Known limitations and trust warnings:
- The stable still-image path is intentionally conservative and can be slow because it materializes stills into intermediate `.mov` clips before final assembly.
- Large HDR `HEVC` exports can take a long time and use substantial CPU, memory, disk, and temporary storage.
- Apple Photos exports depend on Photos permissions and can be affected by PhotoKit/iCloud materialization latency.
- The HEVC bakeoff command is intentionally manual and local-only; it does not auto-pick a winner or change export defaults.
- Balanced bitrate is workable now, but very large 4K60 HDR outputs may still need more tuning for size.
- The chosen randomized opening-title treatment is recorded in the JSON run report, not surfaced in the main UI yet.
- Packaged builds are ad-hoc signed and not notarized, so downloaded copies may still require Finder `Open` or `System Settings -> Privacy & Security -> Open Anyway`.
- The current bundle identifier remains mixed-case (`com.jkfisher.MonthlyVideoGenerator`) pending a separate migration decision; it was intentionally not renamed during this alignment pass.

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
- Verify the rerun `build.yml` and `release.yml` runs end-to-end for `1.2.0` on `macos-15`, then fix any remaining CI-only packaging drift without disturbing render behavior.
- Manually smoke-test the new Mac shell: menus, keyboard shortcuts, Settings, About window, output-folder persistence, and the split main-window workflow with real exports.
- Run the in-app `Run HEVC Bakeoff` command against `Test Export`, then compare the generated candidate videos/stills before deciding whether to retune final HEVC defaults.
- Manually smoke-test several real exports and confirm the randomized collage-family openers stay readable and free of hollow photo-box artifacts.
- Re-tune export defaults and bitrate targets using real-world 4K60 HDR examples.
- Improve progress/cancel/resume UX for long-running FFmpeg/HDR jobs.
- Add a lightweight inspectable UI hint or export-summary note for which title treatment was chosen, if that would help review iteration.

Most recent durable known-good anchor:
- `known-good/20260320-v1-1-0-collage-titles`
