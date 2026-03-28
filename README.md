<p align="center">
  <img src="spk/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="spk logo" width="160">
</p>
# spk
`spk` is a local-only macOS menu bar dictation app. It records short clips, transcribes them on-device with Whisper, and inserts the result into the focused app.

## Requirements
To run the app:
- Apple Silicon or Intel Mac
- macOS 14.0 or newer
- Working microphone
- Ability to grant Microphone and Accessibility permissions
- Local Whisper assets available either in the app bundle or under `~/Library/Application Support/spk/Models`

Current repo defaults:
- `spk/Resources/Models` already contains the default bundled Whisper and VAD assets used for final transcription
- `spk` expects a stable team-signed install when you want macOS to preserve Accessibility trust across rebuilds and reinstalls

To build from source:
- Xcode 16.x or newer
- Xcode Command Line Tools
- `xcodegen`
- Apple Development team ID if you want a stable signed install in `/Applications`
- `cmake` only if you need to rebuild the vendored Whisper framework

```bash
xcode-select --install
brew install xcodegen cmake
```

## Hardware and Limitations Overview
### Platform and Hardware
- `spk` is a native macOS app only. The current repo targets macOS 14.0 and newer.
- Final transcription supports both Apple Silicon and Intel Macs.
- WhisperKit live preview currently requires Apple Silicon.
- A working microphone is required for all recording flows.
- Local storage matters because the app relies on bundled or locally cached model files instead of downloading them at runtime.
- In this repository snapshot, bundled model assets are substantial: `spk/Resources/Models` is about `58 MB`, and `spk/Resources/WhisperKitModels` is about `1.6 GB`.

### Operational Requirements
- `Microphone` permission is required before recording can start.
- `Accessibility` permission is required before `spk` can insert dictated text into other apps.
- A stable team-signed install is strongly recommended for repeated local installs. If the signing identity changes, macOS may ask for Accessibility and Microphone again.
- Final transcription requires local Whisper assets to be present either in the app bundle or in `~/Library/Application Support/spk/Models`.
- Live preview requires a compatible local WhisperKit model in one of the supported local locations; `spk` will not fetch one for you at runtime.
- The current repo bundles an English final-transcription model by default (`ggml-base.en-q5_1.bin`). If you want multilingual dictation on a non-English setup, you should install or bundle a compatible multilingual Whisper model such as `ggml-base-q5_1.bin`.
- Runtime use is local-only. There is no app-initiated cloud transcription, remote inference server, or runtime model download path in the app code.

### Current Product Limitations
- `spk` is currently a menu bar app, not a Dock-first desktop app.
- The global shortcut is fixed to `Cmd+Shift+Space` in the current build. There is no shortcut customization UI in the repo right now.
- Live preview is preview-only: partial text can appear while recording, but the final inserted transcript still comes from the local `whisper.cpp` backend.
- Final transcription uses the vendored Whisper backend in-process and keeps the GPU path opt-in for now, so default behavior should be treated as CPU-first.
- Cross-app insertion depends on macOS accessibility APIs and the focused app's text field behavior. Some targets insert cleanly through Accessibility, while others may require typing or paste fallback.
- Secure fields are intentionally blocked. If `spk` cannot verify that a target is safe and non-secure, it will refuse blind insertion.
- The current UI exposes the latest transcript, but there is no persistent transcript history feature in the repo.
- App sandboxing remains disabled because cross-app insertion is a core workflow and the current implementation depends on that freedom.
- The repo does not yet include a notarized public release pipeline, so Gatekeeper behavior still depends on how a build was signed and distributed.

## Use
- `spk` runs from the macOS menu bar and opens a two-pane window: `Dictation` and `Settings`
- Default shortcut: `Cmd+Shift+Space`
- You can also use the `Start Recording` button in the `Dictation` pane
- Press once to start recording.
- Press it again to stop, transcribe, and insert.
- If the global shortcut fails to register, the Dictation button still works.

## Startup Readiness
On launch, `spk` checks four things before it considers itself ready:

- Stable signed build identity
- Local Whisper backend availability
- Microphone permission
- Accessibility permission

The `Settings` pane mirrors this readiness state and points you to the next action if setup is incomplete.

## Experimental Streaming Preview
`spk` includes an experimental WhisperKit-powered live preview that runs only while recording. It does not change the final transcript or insertion path: when you stop recording, `spk` still finalizes the transcript with the local `whisper.cpp` backend.

Manage it from `Settings` inside the app:

- Turn `Live preview (experimental)` on or off
- If `spk` does not already find a compatible local model, click `Choose Folder`
- Start recording from the `Dictation` pane to see partial text updates live

Notes:
- On Apple Silicon, `spk` enables live preview by default when a compatible local WhisperKit model is already available
- `spk` resolves WhisperKit preview models only from local sources: `SPK_WHISPERKIT_MODEL_PATH`, the folder selected in Settings, bundled app resources, `~/Library/Application Support/spk/WhisperKitModels`, or `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`
- When multiple compatible `base` and `medium` WhisperKit models are present locally, `spk` prefers `medium` automatically
- `spk` will not download WhisperKit models at runtime
- Live preview is currently Apple-Silicon-only
- The open-source WhisperKit local server is not used here; the app integrates WhisperKit directly in-process.
- Developer overrides still work if needed:

```bash
export SPK_EXPERIMENTAL_WHISPERKIT_STREAMING=1
export SPK_WHISPERKIT_MODEL_PATH="/absolute/path/to/local/whisperkit/model-folder"
```

## Settings
The `Settings` pane currently exposes:

- `Live preview (experimental)` for partial WhisperKit text while recording
- `Automatically copy transcripts`, which is off by default
- `Input device`, with a `System Default` option or a specific microphone
- `Input sensitivity`, adjustable from `0.5x` to `2.5x`
- `Allow paste fallback`, which is on by default as a recovery path for verified non-secure fields
- `Collect diagnostics`, which is on by default and keeps a capped in-memory buffer available for `Copy Diagnostics` or `Export Diagnostics`

The menu window also includes `Model Files`, which opens the local Whisper model directory.

## Privacy
- Final transcription uses only bundled or locally installed Whisper model files, plus a local VAD model when available.
- The app does not download models at runtime.
- Recordings are written to a temporary app-specific directory and cleaned up after processing.
- Diagnostics are capped in memory and can be copied or exported manually.
- Paste fallback is on by default, but only used as a recovery path for verified non-secure fields and restores the clipboard when possible.
- App sandboxing is still disabled to preserve the current cross-app insertion workflow.

## Quick Start
```bash
./scripts/run_dev.sh
./scripts/check.sh
```

- `./scripts/run_dev.sh` builds and launches the app locally.
- `./scripts/run_dev.sh` prefetches the default Whisper and VAD assets into `~/Library/Application Support/spk/Models` unless you pass `--skip-model-prefetch`.
- `./scripts/check.sh` runs the full verification flow: setup, Debug build, unit tests, and the privacy/static audit.

## Installation Notes
- End users downloading a prebuilt app do not need an App Store Connect account or any Apple account.
- Anyone can download and run a prebuilt app bundle that you distribute.
- The Apple Development team ID is only needed by the person building a signed local Release app from source with `./scripts/install_release.sh`.
- `spk`'s startup flow expects a stable team-signed build identity when you want Accessibility permission to survive rebuilds.
- This repo does not currently include notarization or a public release pipeline, so Gatekeeper behavior will depend on how the distributed app was signed and shipped.

## AI Release Prompt
```text
You are working in the WhisperType repository and need to turn `spk` into a proper downloadable macOS release for end users.

Project facts:
- `spk` is a native macOS menu bar app built from `project.yml` with XcodeGen.
- Runtime must stay local-only: no app-initiated model downloads, no external runtime servers, bundled/local Whisper and VAD only.
- Cross-app insertion is a core workflow, so do not enable sandboxing if it breaks insertion.
- There is already a local installer script at `./scripts/install_release.sh`.
- End users should be able to download the finished app without needing Xcode, App Store Connect, or a developer environment.

Goals:
- Produce a signed Release build suitable for public download.
- Add a proper downloadable artifact such as a notarized `.dmg` or `.zip`.
- Make Gatekeeper-friendly distribution work on a clean Mac.
- Keep the app's current privacy/runtime guarantees intact.

Please do the following:
1. Audit the current signing, packaging, and release state of the repo.
2. Implement a release pipeline, preferably GitHub Actions, that builds `spk.app`, signs it with Developer ID, notarizes it, staples the notarization ticket, packages it, and publishes it as a release artifact.
3. Make sure the Release app bundles the required Whisper and VAD assets so the shipped app never downloads models at runtime.
4. Add any missing scripts, entitlements, CI configuration, and documentation needed for repeatable releases.
5. Document exactly which maintainer credentials are required to publish releases, such as Apple Developer Program membership, Developer ID certificate, team ID, and notarization credentials.
6. Update the README with clear end-user download/install instructions and clear maintainer release steps.
7. Verify the result on a clean machine or in the closest reproducible way available, and note any remaining Gatekeeper or signing caveats.

Deliverables:
- Updated scripts and project settings
- CI release workflow
- README/release documentation
- Exact commands for maintainers
- A short summary of what still requires manual Apple-side setup
```

## Install To /Applications
```bash
./scripts/install_release.sh --development-team <TEAM_ID>
```
This builds a signed Release app, bundles the local Whisper assets into it, replaces any bundled WhisperKit preview folders with whatever is currently cached under `~/Library/Application Support/spk/WhisperKitModels`, installs `/Applications/spk.app`, resets Microphone and Accessibility permissions, and relaunches the app unless `--no-open` is passed.
If a compatible cached WhisperKit model such as `openai_whisper-medium` exists, the installer also configures `spk` to prefer that model automatically for live preview.

## Models
- Cache models locally with `./scripts/download_whisper_model.sh --cache`
- Bundle models into future app builds with `./scripts/download_whisper_model.sh --bundle`
- Cache a WhisperKit live-preview model with `./scripts/download_whisperkit_preview_model.sh`
