Bundled WhisperKit live-preview model folders live here.

Current repo contents:

- `openai_whisper-base.en/`
- `openai_whisper-medium/`

Expected contents inside each model folder include:

- `AudioEncoder.mlmodelc`
- `TextDecoder.mlmodelc`
- `MelSpectrogram.mlmodelc`
- `tokenizer.json`, or a nested tokenizer under `models/openai/.../tokenizer.json`

Live-preview resolution order:

1. `SPK_WHISPERKIT_MODEL_PATH`
2. The folder chosen from `Settings > Live preview (experimental)`
3. Bundled model folders in this directory
4. `~/Library/Application Support/spk/WhisperKitModels`
5. `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`

When multiple compatible models are available, `spk` prefers `medium` over `base`.

Helpful commands:

- Cache a local preview model with `./scripts/download_whisperkit_preview_model.sh`
- Future Release installs replace bundled preview folders with any cached preview model found under `~/Library/Application Support/spk/WhisperKitModels`

Runtime rules:

- Live preview is currently Apple-Silicon-only.
- `spk` never downloads WhisperKit models at runtime.
- If no bundled, cached, or selected preview model exists, the app falls back to the normal non-streaming Whisper path.
- The final inserted transcript still uses Whisper, not WhisperKit.
