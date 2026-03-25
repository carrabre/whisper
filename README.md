<p align="center">
  <img src="spk/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="spk logo" width="160">
</p>

# spk

spk is a native macOS menu bar dictation app. By default it records short dictation clips, streams English transcription locally through a checkpoint-backed Nemotron runtime prepared from the upstream Hugging Face `.nemo` file, and then tries to insert the transcript into the currently focused app. If you want to dictate in another language, switch the Settings pane to `Multilingual (Whisper)` and spk falls back to the existing local `whisper-medium` pipeline.

## Highlights

- Native `SwiftUI` and `AppKit` menu bar app for macOS
- Default `English realtime (Nemotron)` mode for live English dictation on the local Mac
- Settings-only `Multilingual (Whisper)` fallback when you want non-English speech recognition
- Canonical one-command installer that reinstalls the app, downloads the Nemotron checkpoint directly from Hugging Face, prepares local runtime assets, caches `ggml-medium.bin`, and reopens the app
- Menu bar window with dedicated Dictation and Settings panes
- Best-effort delivery into the focused app through Accessibility insertion, family-specific typing or paste fallback, and clipboard copy
- Secure and password-style fields are intentionally blocked
- Input-device selection, sensitivity control, live input meter, automatic transcript copy, last-transcript card, and debug-log export
- Standalone `Fn / Globe` shortcut support when the current Carbon registration path works on the host Mac

## How It Works

1. `spk` captures the current target app when dictation starts.
2. It records a 16 kHz mono WAV clip into `~/Library/Application Support/spk/Recordings/`.
3. The audio pipeline rejects clips that are too short or effectively silent.
4. In the default English mode, `NemotronBridge` uses the prepared checkpoint-backed runtime under `~/Library/Application Support/spk/Models/nemotron-en/<version>`, streams partial transcripts during recording, and finalizes the same session on stop.
5. In multilingual mode, `WhisperBridge` loads `ggml-medium.bin` from cache or bundle, downloading it automatically if needed, then runs the existing Whisper path.
6. `TextInsertionService` classifies the target app, probes whether the focused element is AX-writable, and then uses a fixed fallback order before copying to the clipboard when delivery fails.

## Repository Layout

- `spk/`: macOS app source code
- `spk/App/`: app entry and high-level orchestration
- `spk/Audio/`: recording, audio devices, settings persistence, and audio cues
- `spk/Insertion/`: focused-app capture and transcript delivery
- `spk/MenuBar/`: menu bar UI, theme, and app branding
- `spk/System/`: permissions and hotkey integration
- `spk/Transcription/`: backend-neutral transcription coordination, Nemotron artifact handling, and Whisper model management
- `spk/Support/`: logging, plist, and support utilities
- `spk/Resources/`: app icons, optional bundled models, and preview resources
- `spkTests/`: hosted unit tests
- `project.yml`: XcodeGen source of truth
- `spk.xcodeproj/`: generated Xcode project
- `scripts/`: development, backend-artifact, release-install, and asset helper scripts
- `Vendor/whisper.cpp/`: vendored upstream runtime source
- `Vendor/whisper.xcframework/`: embedded Whisper framework used by the app

## Project Notes

- `project.yml` is the source of truth for the Xcode project. Regenerate `spk.xcodeproj` instead of hand-editing project settings.
- The app target is `spk` with bundle identifier `com.acfinc.spk`.
- The project currently targets macOS `13.3` with Swift `5.10`.
- `spk` runs as an `LSUIElement` menu bar app with no Dock icon.
- App sandboxing is currently disabled.

## Key Runtime Components

- `spk/App/SpkApp.swift`: app entry point, `MenuBarExtra`, and root state objects
- `spk/App/WhisperAppState.swift`: permissions, mode-aware model setup, recording, transcription, insertion flow, and UI state
- `spk/MenuBar/MenuBarView.swift`: Dictation and Settings panes
- `spk/Audio/AudioRecorder.swift`: 16 kHz mono recording and temporary microphone switching
- `spk/Audio/AudioSettingsStore.swift`: persisted input-device, sensitivity, auto-copy, and cue preferences
- `spk/System/PermissionsManager.swift`: microphone and accessibility state plus System Settings deep links
- `spk/System/HotkeyManager.swift`: experimental Carbon registration for standalone `Fn / Globe`
- `spk/Transcription/TranscriptionCoordinator.swift`: backend-neutral streaming and finalization contract
- `spk/Transcription/NemotronBridge.swift`: versioned Nemotron English artifact download and streaming runner bridge
- `spk/Transcription/WhisperBridge.swift`: Whisper cache and bundle lookup, download, and `whisper_full` execution
- `spk/Insertion/TextInsertionService.swift`: focused-app capture and insertion strategy fallback order
- `spk/Support/DebugLog.swift`: file logging under `~/Library/Application Support/spk/Logs/`

## Prerequisites

- macOS 13.3 or newer
- Xcode 15.x or newer
- Xcode Command Line Tools
- `xcodegen`
- Homebrew is recommended so the installer can provision `python@3.12` automatically for the managed Nemotron runtime when needed
- `cmake` if you want to rebuild the embedded Whisper framework

Example setup:

```bash
xcode-select --install
brew install xcodegen cmake
```

## Super Simple Installation Instructions

This is the quickest path from cloning the repo to having a normal installed copy of `spk.app` with both local model caches already downloaded under `~/Library/Application Support/spk/Models`.

1. Install Xcode 15 or newer, then install the command line tools.

```bash
xcode-select --install
```

2. Clone the repo and enter it.

```bash
git clone https://github.com/carrabre/whisper.git WhisperType
cd WhisperType
```

3. Install the app with the canonical delete-and-reinstall script. It generates `spk.xcodeproj` if needed, removes the old `/Applications/spk.app`, installs the managed NeMo Python runtime, downloads the upstream Nemotron `.nemo` checkpoint directly from Hugging Face, stages the local checkpoint-backed runtime, caches `ggml-medium.bin` in the same parent model directory, builds the Release app, installs it, and relaunches only after the install succeeds.

```bash
./scripts/install_release.sh --development-team <TEAM_ID>
```

If you already have a compatible Python 3.10-3.12 interpreter you want to use for the managed Nemotron runtime, point the installer at it:

```bash
SPK_NEMOTRON_RUNTIME_PYTHON=/path/to/python ./scripts/install_release.sh --development-team <TEAM_ID>
```

4. On first launch, or any time you change the signing identity, re-grant `Microphone` and `Accessibility` when macOS asks. `spk` now requests startup permissions automatically where macOS allows it, and it stays blocked until the selected backend is actually ready.

If `Fn / Globe` does not respond on your Mac, use the in-app record button instead.

## Setup

Regenerate the Xcode project when `project.yml` changes:

```bash
xcodegen generate
```

Open the project:

```bash
open spk.xcodeproj
```

Choose a real Apple Development team when building Release if you want stable macOS permission identity across rebuilds. The easiest path is `./scripts/install_release.sh --development-team <TEAM_ID>`.

## Build, Run, and Test

Run the local debug helper:

```bash
./scripts/run_dev.sh
```

`run_dev.sh` automatically prepares the default Nemotron runtime from the Hugging Face checkpoint and caches `ggml-medium.bin` before launching unless you set `SPK_SKIP_MODEL_PREFETCH=1`.

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

The Debug app will be at:

```bash
.build/Build/Products/Debug/spk.app
```

Run tests:

```bash
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -destination "platform=macOS" \
  test
```

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

Install a local release build:

```bash
./scripts/install_release.sh --development-team <TEAM_ID>
```

## Transcription Modes

`spk` exposes two transcription modes in Settings:

- `English realtime (Nemotron)`: the default. Uses a versioned checkpoint-backed runtime under Application Support, streams live English text while you record, and finalizes the transcript from the same backend when you stop. The canonical install and dev scripts prepare that runtime from the upstream Hugging Face checkpoint before launch.
- `Multilingual (Whisper)`: use this when you want to speak a non-English language. It keeps the existing `whisper-medium` model and stop-time final transcription path.

Mode switching is Settings-only in v1. The app prepares only the selected backend and lazily downloads the other one if you switch later.

## Model And Artifact Management

Runtime cache locations:

- Shared parent cache root: `~/Library/Application Support/spk/Models`

Default English asset locations:

- Cache root: `~/Library/Application Support/spk/Models/nemotron-en`
- Versioned pack: `~/Library/Application Support/spk/Models/nemotron-en/<version>`

Prefetch the default English pack manually:

```bash
./scripts/download_nemotron_artifact.sh --cache
```

By default this script installs the managed NeMo Python runtime, downloads the upstream `.nemo` checkpoint directly from Hugging Face, stages the local runner and manifest, and validates the resulting runtime directory under the cache root above. If you already host a prebuilt runtime zip, you can override that path with `SPK_NEMOTRON_ARTIFACT_URL`. The expected runtime version can be overridden with `SPK_NEMOTRON_ARTIFACT_VERSION`.

Whisper fallback asset locations:

- Cache: `~/Library/Application Support/spk/Models/ggml-medium.bin`
- Bundled copy: `spk/Resources/Models/ggml-medium.bin`

Cache the Whisper model manually:

```bash
./scripts/download_whisper_model.sh --cache
```

Bundle the Whisper model into future app builds:

```bash
./scripts/download_whisper_model.sh --bundle
```

The bundled `whisper.xcframework` is built with Metal and CoreML support, but `WhisperBridge` currently loads the model with GPU disabled for runtime stability.

Nemotron English is distributed under NVIDIA's open model license. Whisper model weights and the embedded `whisper.cpp` runtime retain their own separate licensing terms.

## Permissions And System Behavior

- `Microphone` access is required to record dictation.
- `Accessibility` access is required to insert text into other apps.
- Use a team-signed Release build for stable Accessibility identity. Ad hoc builds can force you to remove and re-add the app in System Settings after rebuilds.
- Browsers, Electron apps, code editors, and terminals are treated as final-insert targets by default. `spk` waits until recording stops, then inserts once with paste or typing fallback if direct AX insertion is not reliable.
- The current hotkey implementation does not expose an Input Monitoring setup flow in the app. It attempts to register `Fn / Globe` through Carbon; if that is unavailable on your Mac, use the in-app record button instead.
- `spk` intentionally blocks insertion into secure or password-style fields.
- Some apps still reject synthetic input entirely. In those cases the transcript can still be copied from the app or delivered to the clipboard automatically.

If Accessibility appears enabled but insertion still fails:

1. Confirm you launched the exact `/Applications/spk.app` bundle that `./scripts/install_release.sh --development-team <TEAM_ID>` installed.
2. If the signing identity changed, re-grant `Microphone` and `Accessibility` when macOS prompts.
3. If macOS still points at an older identity, remove the existing `spk` entry from `System Settings > Privacy & Security > Accessibility` and re-add the current app bundle.

## Scripts And Maintenance

- `scripts/install_release.sh`: canonical one-command local installer that generates the Xcode project if needed, prepares both backend caches, rebuilds the Release app, replaces `/Applications/spk.app`, resets TCC permissions, and relaunches it
- `scripts/run_dev.sh`: prepare both backend caches, build Debug, and launch the app binary
- `scripts/download_nemotron_artifact.sh`: install the managed NeMo Python runtime, download the Nemotron checkpoint directly from Hugging Face, and stage the local runtime into the cache, or use `SPK_NEMOTRON_ARTIFACT_URL` to fetch a prebuilt runtime zip
- `scripts/download_whisper_model.sh`: download `whisper-medium` into the cache, bundle, or a custom destination
- `scripts/setup_nemotron_python.sh`: create or refresh the managed Python runtime used by the Nemotron English backend
- `scripts/export_nemotron_artifact.sh`: maintainer-only helper that prepares the checkpoint-backed Nemotron runtime and packages a macOS zip
- `scripts/package_nemotron_artifact.sh`: package a prepared Nemotron runtime directory into a versioned zip
- `scripts/generate_app_icon.swift`: regenerate the app icon PNG set and `AppIcon.icns`
- `Vendor/Scripts/build_whisper_xcframework.sh`: rebuild `Vendor/whisper.xcframework` from `Vendor/whisper.cpp`

## Tests

- `spkTests/WhisperAppStateTests.swift`: app-state orchestration, hotkey behavior, transcription flow, and clipboard outcomes
- `spkTests/AudioSettingsStoreTests.swift`: persisted transcript-copy and audio-cue settings
- `spkTests/TextInsertionServiceTests.swift`: insertion strategy order, secure-field blocking, focused-target selection, and clipboard fallback

## Troubleshooting

- If the app records but does not insert text, confirm Accessibility is granted to the exact team-signed app bundle you launched.
- If `Fn / Globe` does not respond, the Carbon registration path may not be available on your Mac. Use the record button and check the app status copy.
- If the target app exposes a custom editor, browser surface, terminal, or Electron field, `spk` may wait until stop and then fall back to paste or typing. If both fail, copy the transcript from the UI or clipboard.
- If the default English backend fails to prepare, remove any incomplete pack inside `~/Library/Application Support/spk/Models/nemotron-en` and retry.
- If the multilingual fallback fails to prepare, remove any incomplete `ggml-medium.bin` file in `~/Library/Application Support/spk/Models` and retry.
- If you need diagnostics, use the in-app debug log controls or inspect `~/Library/Application Support/spk/Logs/debug.log`.
