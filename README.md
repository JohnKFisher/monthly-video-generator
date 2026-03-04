# Monthly Video Generator

Monthly Video Generator is a local-only macOS app that builds slideshow videos from media in folders and Apple Photos.

## Safety and Workflow

This project follows a strict milestone workflow:

1. Milestone updates are required when a stage gate is completed or behavior/scope/decisions materially change.
2. `docs/LIVING_PLAN.md` must be updated before claiming milestone completion.
3. Milestone checkpoint commits/tags must include the living document update.
4. Work is not complete unless the living document reflects current truth.

## Build

```bash
swift build
```

## Build `.app` Bundle

```bash
./scripts/build_app.sh
```

This creates:

- `dist/MonthlyVideoGenerator.app`

Optional override:

```bash
BUILD_NUMBER=42 ./scripts/build_app.sh
```

## Test

```bash
swift test
```

## Run

```bash
swift run MonthlyVideoGeneratorApp
```
