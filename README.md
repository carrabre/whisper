# spk

spk is a native macOS menu bar app that records with a global hotkey, transcribes speech locally with [whisper-medium](https://huggingface.co/openai/whisper-medium), and inserts the result into the currently focused app on a best-effort basis.

## Features

- Native `SwiftUI` / `AppKit` menu bar app for macOS
- Hold-to-talk shortcut: `Command + Shift + Space`
- Local transcription through a vendored `whisper.cpp` runtime
- Automatic first-run model download and caching, with optional prefetch/bundling scripts
- Best-effort text insertion into most active apps through Accessibility, typed input, and clipboard paste fallback
- Input-device selection, sensitivity control, and debug-log export

## Repository Layout

- `spk/`: app source code
- `spk.xcodeproj/`: generated Xcode project
- `project.yml`: XcodeGen source of truth
- `Vendor/whisper.cpp/`: vendored upstream runtime source
- `Vendor/whisper.xcframework/`: embedded Whisper framework used by the app
- `Vendor/Scripts/build_whisper_xcframework.sh`: rebuild script for the embedded framework
- `scripts/`: project utility scripts

## Prerequisites

- macOS 13.3 or newer
- Xcode 15.x or newer
- Xcode Command Line Tools
- `xcodegen`
- `cmake` if you want to rebuild the embedded Whisper framework

Example setup:

```bash
xcode-select --install
brew install xcodegen cmake
```

## Development

Regenerate the Xcode project when `project.yml` changes:

```bash
xcodegen generate
```

Open the project:

```bash
open spk.xcodeproj
```

Choose a real development team in Xcode under `Signing & Capabilities` for the `spk` target if you want stable macOS permission identity across rebuilds.

Build from the terminal:

```bash
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath ".build" \
  build
```

The Debug app will be at:

```bash
.build/Build/Products/Debug/spk.app
```

Run the debug helper:

```bash
./scripts/run_dev.sh
```

`run_dev.sh` automatically caches `ggml-medium.bin` before launching unless you set `SPK_SKIP_MODEL_PREFETCH=1`.

## Model Setup

spk already downloads `ggml-medium.bin` automatically on first launch if it is missing.

If you want to prefetch it yourself:

```bash
./scripts/download_whisper_model.sh
```

That downloads the model to:

```bash
~/Library/Application Support/spk/Models/ggml-medium.bin
```

If you want future builds to embed the model inside the `.app` bundle:

```bash
./scripts/download_whisper_model.sh --bundle
```

## First Launch

On first launch, spk will:

- request `Microphone` access when needed
- request `Accessibility` access when needed
- use `~/Library/Application Support/spk/Models/ggml-medium.bin` if it already exists
- otherwise download `ggml-medium.bin` automatically unless a bundled model already exists

If Accessibility appears enabled but typing still fails:

1. Remove the existing `spk` entry from `System Settings > Privacy & Security > Accessibility`.
2. Re-add the exact `.app` bundle you are launching now.
3. Prefer a development-signed build over an ad-hoc build.

spk intentionally blocks insertion into secure/password-style fields when Accessibility identifies them, and some apps may still reject synthetic input entirely.

## Install

Build a release app:

```bash
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath ".release" \
  build
```

If you want the release app to work offline on first launch, run `./scripts/download_whisper_model.sh --bundle` before building so the model is copied into the app bundle.

Install it locally:

```bash
rm -rf "/Applications/spk.app"
cp -R ".release/Build/Products/Release/spk.app" "/Applications/spk.app"
open "/Applications/spk.app"
```

## Troubleshooting

- If the app records but does not insert text, confirm Accessibility is granted to the exact app bundle you launched.
- If the target app exposes a custom editor, spk may fall back to synthetic typing or paste; if both fail, the transcript is copied to the clipboard instead.
- If the model download fails, remove any incomplete file in `~/Library/Application Support/spk/Models`.
- If you need transcription diagnostics, use the in-app debug log controls or inspect `~/Library/Application Support/spk/Logs/debug.log`.
