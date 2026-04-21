# Monthly Video Generator Decision Log

## 2026-04-20

- Decision: Treat the render, color, HDR, and final export pipeline as protected project behavior during repo modernization. Rationale: the app's core value is reliable output quality, and alignment work must not casually disturb hard-won render behavior. Status: approved.
- Decision: Use source-controlled `VERSION` and `BUILD_NUMBER` as the release identity for the app. `scripts/build_app.sh` reads those values without mutating them, and `scripts/prepare_release.sh` is the intentional path that bumps both together for a publishable release. Rationale: release state should come from committed source, not from local packaging side effects. Status: approved.
- Decision: Add first-time GitHub Actions automation with separate `build.yml` and `release.yml` workflows that package the app through the repo's shared shell scripts and publish ad-hoc-signed, non-notarized macOS DMGs. Rationale: the repo is being prepared for initial GitHub publication, but distribution docs must stay honest about trust-policy limitations. Status: approved.
- Decision: Keep the existing mixed-case bundle identifier `com.jkfisher.MonthlyVideoGenerator` unchanged during this round and revisit only with an explicit migration plan later. Rationale: the new lowercase-only default is sensible for future projects, but identity changes can affect preferences, signing, and distribution continuity. Status: approved.
