<p align="center">
  <img src="spk/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="spk logo" width="160">
</p>

# spk

`spk` is a native macOS menu bar dictation app. It records short clips, runs local transcription with a low-latency quantized Whisper model, and inserts the finished transcript into the focused app.

## Highlights

- Native `SwiftUI` and `AppKit` menu bar app for macOS
- Single local Whisper pipeline tuned for low-latency dictation
- Single final Whisper transcription pass when you stop recording
- Automatic model download and cache reuse under `~/Library/Application Support/spk/Models`
- Focused-app insertion with Accessibility typing or clipboard fallback
- Input-device selection, sensitivity control, live input meter, transcript copy, and debug-log export

## How It Works

1. `spk` captures the current insertion target when dictation starts.
2. It records a 16 kHz mono WAV clip into `~/Library/Application Support/spk/Recordings/`.
3. `WhisperBridge` loads the preferred low-latency Whisper model from cache or bundle, downloading it automatically if needed and falling back to older cached models if necessary.
4. When you stop, `spk` prepares the full recording and runs one final Whisper transcription pass.
5. `spk` then inserts the transcript into the focused app or copies it to the clipboard, depending on the result.

## Repository Layout

- `spk/`: macOS app source
- `spk/App/`: app lifecycle and orchestration
- `spk/Audio/`: recording, devices, settings, and audio cues
- `spk/Insertion/`: focused-app capture and transcript delivery
- `spk/MenuBar/`: menu bar UI and theme
- `spk/System/`: permissions and hotkey integration
- `spk/Transcription/`: Whisper model management and transcription coordination
- `spkTests/`: hosted unit tests
- `scripts/`: development and install helpers
- `project.yml`: XcodeGen source of truth
- `Vendor/whisper.xcframework/`: embedded Whisper framework used by the app

## Prerequisites

- macOS 14.0 or newer
- Xcode 15.x or newer
- Xcode Command Line Tools
- `xcodegen`
- `cmake` if you want to rebuild the embedded Whisper framework

Example setup:

```bash
xcode-select --install
brew install xcodegen cmake
```

## Quick Start

Prepare the repo once:

```bash
./scripts/setup.sh
```

Run the full local verification flow:

```bash
./scripts/check.sh
```

Build and launch the Debug app:

```bash
./scripts/run_dev.sh
```

Run just the hosted unit tests:

```bash
./scripts/test.sh
```

## Install To /Applications

```bash
./scripts/install_release.sh --development-team <TEAM_ID>
```

The installer:

- regenerates `spk.xcodeproj` if needed
- prefetches the preferred low-latency Whisper model
- builds a Release app
- installs `/Applications/spk.app`
- resets Microphone and Accessibility permissions
- relaunches the app unless `--no-open` is passed

## Advanced Commands

If you only want a Debug build without launching the app:

```bash
./scripts/run_dev.sh --build-only
```

If you want setup or verification without downloading the Whisper model again:

```bash
./scripts/setup.sh --skip-model-prefetch
./scripts/check.sh --skip-model-prefetch
```

## Model Management

Runtime cache:

- `~/Library/Application Support/spk/Models/ggml-base.en-q5_1.bin`
- `~/Library/Application Support/spk/Models/ggml-base-q5_1.bin`

Optional bundled model:

- `spk/Resources/Models/ggml-base.en-q5_1.bin`
- `spk/Resources/Models/ggml-base-q5_1.bin`

Prefetch the model manually:

```bash
./scripts/download_whisper_model.sh --cache
```

Bundle the model into future app builds:

```bash
./scripts/download_whisper_model.sh --bundle
```

## Notes

- `project.yml` is the source of truth for `spk.xcodeproj`.
- `spk` runs as an `LSUIElement` menu bar app with no Dock icon.
- App sandboxing is currently disabled.
