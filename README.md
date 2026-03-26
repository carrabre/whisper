<p align="center">
  <img src="spk/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="spk logo" width="160">
</p>

# spk

`spk` is a native macOS menu bar dictation app. It records short clips, runs local transcription with `whisper-medium`, and inserts the finished transcript into the focused app.

## Highlights

- Native `SwiftUI` and `AppKit` menu bar app for macOS
- Single local Whisper pipeline based on `whisper-medium`
- Live preview while recording, with final transcript delivery when you stop
- Automatic model download and cache reuse under `~/Library/Application Support/spk/Models`
- Focused-app insertion with Accessibility typing or clipboard fallback
- Input-device selection, sensitivity control, live input meter, transcript copy, and debug-log export

## How It Works

1. `spk` captures the current insertion target when dictation starts.
2. It records a 16 kHz mono WAV clip into `~/Library/Application Support/spk/Recordings/`.
3. `WhisperBridge` loads `ggml-medium.bin` from cache or bundle, downloading it automatically if needed.
4. During recording, `spk` polls live audio and shows Whisper-based preview text as words stabilize.
5. When you stop, `spk` prepares the full recording and runs final Whisper transcription before inserting or copying the transcript.

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

## Install

```bash
./scripts/install_release.sh --development-team <TEAM_ID>
```

The installer:

- regenerates `spk.xcodeproj` if needed
- prefetches `ggml-medium.bin`
- builds a Release app
- installs `/Applications/spk.app`
- resets Microphone and Accessibility permissions
- relaunches the app unless `--no-open` is passed

## Build and Run

Run the local debug helper:

```bash
./scripts/run_dev.sh
```

Build Debug from the terminal:

```bash
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath ".build" \
  build
```

Run tests:

```bash
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -destination "platform=macOS" \
  test
```

## Model Management

Runtime cache:

- `~/Library/Application Support/spk/Models/ggml-medium.bin`

Optional bundled model:

- `spk/Resources/Models/ggml-medium.bin`

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
