# WhisperType

WhisperType is a native macOS menu bar app that records with a global hotkey, transcribes speech locally with `whisper-medium`, and inserts the result into the currently focused app.

## Features

- Native `SwiftUI` / `AppKit` menu bar app for macOS
- Hold-to-talk shortcut: `Command + Shift + Space`
- Local transcription through a vendored `whisper.cpp` runtime
- Automatic first-run model download and caching
- Text insertion into the active app through Accessibility, with clipboard paste fallback

## Tech Stack

- Swift 5.10
- Xcode project generated from `project.yml` with `XcodeGen`
- Vendored `whisper.cpp` source in `Vendor/whisper.cpp`
- Prebuilt local framework in `Vendor/whisper.xcframework`

## Repository Layout

- `WhisperType/`: app source code
- `WhisperType.xcodeproj/`: Xcode project
- `project.yml`: XcodeGen source of truth
- `Vendor/whisper.cpp/`: vendored upstream runtime source
- `Vendor/whisper.xcframework/`: embedded Whisper framework used by the app
- `Vendor/Scripts/build_whisper_xcframework.sh`: rebuild script for the embedded framework
- `scripts/`: project utility scripts

## Prerequisites

Before running the app locally, install:

- macOS 13.3 or newer
- Xcode 15.x or newer
- Xcode Command Line Tools
- `xcodegen`
- `cmake` if you want to rebuild the embedded Whisper framework

Example setup with Homebrew:

```bash
xcode-select --install
brew install xcodegen cmake
```

## Run Locally In Development

### 1. Clone the repository

```bash
git clone https://github.com/carrabre/whisper.git
cd whisper
```

### 2. Regenerate the Xcode project if needed

The repo already includes `WhisperType.xcodeproj`, but if `project.yml` changes you should regenerate it:

```bash
xcodegen generate
```

### 3. Rebuild the bundled Whisper framework only if needed

You usually do not need this because `Vendor/whisper.xcframework` is already checked in. Run it only when updating the vendored runtime:

```bash
./Vendor/Scripts/build_whisper_xcframework.sh
```

### 4. Open the project in Xcode

```bash
open WhisperType.xcodeproj
```

### 5. Set signing for development

In Xcode, open the `WhisperType` target and choose a real team under `Signing & Capabilities`.

This matters because Accessibility trust is tied to the signed app bundle. With ad-hoc signing, macOS can show the Accessibility toggle as enabled while `AXIsProcessTrusted()` still returns `false` after a rebuild or reinstall.

### 6. Run the app

Run the `WhisperType` scheme from Xcode, or build from the terminal:

```bash
xcodebuild \
  -project "WhisperType.xcodeproj" \
  -scheme "WhisperType" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath ".build" \
  build
```

The built app will be available at:

```bash
.build/Build/Products/Debug/WhisperType.app
```

You can launch it directly with:

```bash
open ".build/Build/Products/Debug/WhisperType.app"
```

## First Launch Setup

On first launch, WhisperType will:

- request `Microphone` access when needed
- request `Accessibility` access when needed
- download `ggml-medium.bin` into `~/Library/Application Support/WhisperType/Models` unless a bundled model already exists

If `Accessibility` appears enabled but WhisperType still cannot type into other apps:

1. Remove the existing `WhisperType` entry from `System Settings > Privacy & Security > Accessibility`.
2. Re-add the exact `.app` bundle you are launching now.
3. Prefer a development-signed build over an ad-hoc build.

## Using The App

1. Launch WhisperType.
2. Grant `Microphone` and `Accessibility` access from the menu bar UI.
3. Wait for the model to finish preparing.
4. Focus a text field in another app.
5. Hold `Command + Shift + Space` to record.
6. Release the shortcut to transcribe and insert text.

You can also use `Record Without Inserting` to test recording and transcription without typing into another app.

## Build A Release App

To create a release build locally:

```bash
xcodebuild \
  -project "WhisperType.xcodeproj" \
  -scheme "WhisperType" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath ".release" \
  build
```

The resulting app bundle will be:

```bash
.release/Build/Products/Release/WhisperType.app
```

## Install The App On A Mac

To install the built app on your own machine:

```bash
rm -rf "/Applications/WhisperType.app"
cp -R ".release/Build/Products/Release/WhisperType.app" "/Applications/WhisperType.app"
open "/Applications/WhisperType.app"
```

After copying it into `/Applications`, re-check `Microphone` and `Accessibility` permissions for that installed app bundle if macOS prompts again.

## Distribute The App To Another Mac

For personal local use, copying the `.app` bundle is enough.

For distribution to other computers, you should:

1. Build a signed release with your Apple Developer account.
2. Archive and export the app from Xcode.
3. Notarize the exported app before sharing it.

Without signing and notarization, Gatekeeper may block the app or show warnings on other Macs.

## Model Notes

- The default runtime model is `ggml-medium.bin`.
- If `WhisperType/Resources/Models/ggml-medium.bin` exists in the app bundle, the app uses it before attempting a network download.
- Otherwise the app downloads the model from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin) on first run.

## Troubleshooting

### Xcode project looks out of date

Regenerate it:

```bash
xcodegen generate
```

### Embedded Whisper framework needs to be rebuilt

```bash
./Vendor/Scripts/build_whisper_xcframework.sh
```

### The app records but does not insert text

- Confirm `Accessibility` access is granted to the exact app bundle you launched.
- Try launching the installed app from `/Applications` instead of a freshly rebuilt bundle.
- Some apps expose limited Accessibility editing APIs, so WhisperType may fall back to clipboard paste.

### The model download fails

- Check your network connection.
- Delete any incomplete file in `~/Library/Application Support/WhisperType/Models`.
- Relaunch the app and retry model preparation.

## Verification

Useful verification commands:

```bash
xcodebuild \
  -project "WhisperType.xcodeproj" \
  -scheme "WhisperType" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath ".build" \
  build
```

```bash
xcodebuild \
  -project "WhisperType.xcodeproj" \
  -scheme "WhisperType" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath ".release" \
  build
```
