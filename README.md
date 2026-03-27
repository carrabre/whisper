<p align="center">
  <img src="spk/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="spk logo" width="160">
</p>
# spk
`spk` is a local macOS menu bar dictation app. It records short clips, transcribes them with a local Whisper pipeline, and inserts the result into the focused app.

## Requirements
To use the app:
- Apple Silicon or Intel Mac
- macOS 14.0 or newer
- Working microphone
- Ability to grant Microphone and Accessibility permissions
- Local Whisper model files available either in the app bundle or under `~/Library/Application Support/spk/Models`

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

## Use
- Default shortcut: `Cmd+Shift+Space`
- Press once to start recording.
- Press it again to stop, transcribe, and insert.

## Experimental Streaming Preview
`spk` now includes an experimental WhisperKit-powered live preview prototype that runs only while recording. It does not change the final transcript or insertion path: when you stop recording, `spk` still finalizes the transcript with the existing local `whisper.cpp` backend.

Enable it from `Settings` inside the app:

- Turn on `Live preview (experimental)`
- If `spk` does not already find a bundled or cached WhisperKit model, click `Choose Folder`
- Start recording from the `Dictation` pane to see partial text updates live

Notes:
- `spk` resolves WhisperKit preview models only from local sources: a selected folder, a bundled app resource, or a local cache under `~/Library/Application Support/spk/WhisperKitModels`
- When both compatible `base` and `medium` WhisperKit models are present locally, `spk` now prefers the downloaded `medium` model automatically.
- `spk` will not download WhisperKit models at runtime
- This prototype is currently treated as Apple-Silicon-only until Intel validation is completed.
- The open-source WhisperKit local server is not used here; the app integrates WhisperKit directly in-process.
- Developer overrides still work if needed:

```bash
export SPK_EXPERIMENTAL_WHISPERKIT_STREAMING=1
export SPK_WHISPERKIT_MODEL_PATH="/absolute/path/to/local/whisperkit/model-folder"
```

## Privacy
- Runtime transcription uses only bundled or locally installed Whisper and VAD model files.
- The app does not download models at runtime.
- Recordings are written to a temporary app-specific directory and cleaned up after processing.
- Diagnostics stay in memory until you explicitly copy or export them.
- Paste fallback is off by default and only allowed for verified non-secure fields.
- App sandboxing is still disabled to preserve the current cross-app insertion workflow.

## Quick Start
```bash
./scripts/run_dev.sh
./scripts/check.sh
```

- `./scripts/run_dev.sh` builds and launches the app locally.
- `./scripts/check.sh` runs the full verification flow.

## Installation Notes
- End users downloading a prebuilt app do not need an App Store Connect account or any Apple account.
- Anyone can download and run a prebuilt app bundle that you distribute.
- The Apple Development team ID is only needed by the person building a signed local Release app from source with `./scripts/install_release.sh`.
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
This builds a signed Release app, bundles the local Whisper assets into it, bundles any cached WhisperKit preview model if available, installs `/Applications/spk.app`, resets Microphone and Accessibility permissions, and relaunches the app unless `--no-open` is passed.
If a compatible downloaded WhisperKit model such as `openai_whisper-medium` exists in the standard local cache, the installer also wires `spk` to prefer that model automatically for live preview.

## Models
- Cache models locally with `./scripts/download_whisper_model.sh --cache`
- Bundle models into future app builds with `./scripts/download_whisper_model.sh --bundle`
- Cache a WhisperKit live-preview model with `./scripts/download_whisperkit_preview_model.sh`
