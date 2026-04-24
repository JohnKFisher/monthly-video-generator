# Monthly Video Generator Decision Log

## 2026-04-20

- Decision: Treat the render, color, HDR, and final export pipeline as protected project behavior during repo modernization. Rationale: the app's core value is reliable output quality, and alignment work must not casually disturb hard-won render behavior. Status: approved.
- Decision: Use source-controlled `VERSION` and `BUILD_NUMBER` as the release identity for the app. `scripts/build_app.sh` reads those values without mutating them, and `scripts/prepare_release.sh` is the intentional path that bumps both together for a publishable release. Rationale: release state should come from committed source, not from local packaging side effects. Status: approved.
- Decision: Add first-time GitHub Actions automation with separate `build.yml` and `release.yml` workflows that package the app through the repo's shared shell scripts and publish ad-hoc-signed, non-notarized macOS DMGs. Rationale: the repo is being prepared for initial GitHub publication, but distribution docs must stay honest about trust-policy limitations. Status: approved.
- Decision: Keep the existing mixed-case bundle identifier `com.jkfisher.MonthlyVideoGenerator` unchanged during this round and revisit only with an explicit migration plan later. Rationale: the new lowercase-only default is sensible for future projects, but identity changes can affect preferences, signing, and distribution continuity. Status: approved.

## 2026-04-21

- Decision: Remove the experimental `tmp/hdr_sdr_iter` artifacts from tracked history before the first GitHub push and ignore `tmp/` going forward. Rationale: those files are disposable scratch outputs, materially bloat the public repository, and are not part of the shipping app, build inputs, or release artifacts. Status: approved.
- Decision: Run GitHub Actions packaging/release workflows on `macos-15` for this repo's first public CI path. Rationale: the package requires Swift tools `6.0`, and the initial `macos-14` runner defaulted to Swift `5.10`, causing the first remote `swift build` step to fail before packaging or release creation. Status: approved.
- Decision: Modernize the macOS shell with native scenes, commands, toolbar ownership, Settings, and bookmark-backed file handling while keeping render/color/HDR/export behavior protected. Rationale: the app needed to feel more Mac-native, but the render pipeline is the app’s core job and should not be casually reshaped during UI modernization. Status: approved.
- Decision: Add an explicit app-only `Run HEVC Bakeoff` command that drives the existing manual `Test Export` comparison harness from the signed app process. Rationale: the command-line/test runner could not reliably obtain Photos authorization, while an in-app launch path can request the permission in the process that actually needs it without changing the default export pipeline. Status: superseded on 2026-04-23.

## 2026-04-22

- Decision: Change the default Plex/Infuse HDR final `libx265` tuning to the bakeoff-approved `crf21-fast` profile. Rationale: the `Test Export` bakeoffs showed materially smaller files and faster renders than the prior default without an obvious visible regression in the reviewed artifacts, and the user explicitly approved promoting that result. Status: approved.

## 2026-04-23

- Decision: Add audit-only progressive HDR presentation timing breakdowns by clip kind and capture-date-overlay state, and surface them in diagnostics plus structured run reports without changing render behavior. Rationale: the current export-speed audit needs better truth about still/title/video presentation cost, but the protected HDR/render/output path should remain behaviorally unchanged until any candidate optimization earns a separate bakeoff. Status: approved.
- Decision: Treat bundled `ffprobe` trustworthiness as a probe-resolution problem first, not a full bundled FFmpeg refresh. Rationale: the current bundled `ffprobe` artifact is present but not launchable on this machine, while the bundled `ffmpeg` remains part of the protected export path; rejecting unusable probes and falling back to a working system probe in auto modes restores trustworthy diagnostics without reopening the shipped render dependency. Status: approved.
- Decision: Remove the in-app HEVC bakeoff feature and the related experimental fast-path plumbing after the still/title bakeoff failed to earn promotion. Rationale: the bakeoff path was useful for local investigation, but the approved export defaults remain unchanged, the tested fast path was neither output-identical nor faster overall, and leaving dormant bakeoff-specific code in the shipping app creates unnecessary surface area. Status: approved.
- Decision: Ship the cleanup-only `2.0.0` release after removing the in-app bakeoff surface and related experimental plumbing, without changing the protected export defaults. Rationale: the app crossed a clear product boundary from experimental local bakeoff tooling back to the stable protected HDR/export path, and the user explicitly approved a major-version release event for that cleanup. Status: approved.

## 2026-04-24

- Decision: Let Photos album renders span multiple months by using the earliest dated album item for Plex month/year identity and the album title for auto-managed episode/output naming. Rationale: album selection is an intentional user scope, so mixed-month albums should not be blocked by the stricter folder/manual month-year resolver. Status: approved.
- Decision: Add an always-visible live snapshot/status inspector that reports completed render artifacts and extracts low-frequency still snapshots without trying to play actively growing files. Rationale: long exports need clearer liveness, but the protected render/output path should not be slowed or made brittle by decoding files that FFmpeg is still writing. Status: approved.
- Decision: Commit the pinned bundled FFmpeg/ffprobe toolchain and make it a required packaging input. Rationale: clean CI checkouts were publishing tiny DMGs without `Contents/Resources/FFmpeg`, causing bundled-preferred HDR exports to fail at runtime; committing validated macOS architecture slices and assembling the packaged tools during `build_app.sh` makes release artifacts deterministic without crossing GitHub's per-file size limit. Status: approved.
