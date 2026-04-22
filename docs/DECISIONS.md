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
- Decision: Add an explicit app-only `Run HEVC Bakeoff` command that drives the existing manual `Test Export` comparison harness from the signed app process. Rationale: the command-line/test runner could not reliably obtain Photos authorization, while an in-app launch path can request the permission in the process that actually needs it without changing the default export pipeline. Status: approved.
