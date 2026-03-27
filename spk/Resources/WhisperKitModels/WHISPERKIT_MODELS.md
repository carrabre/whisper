Place optional bundled WhisperKit live-preview model folders here, for example:

- `openai_whisper-base.en/`
- `openai_whisper-base/`

Expected contents inside each model folder include:

- `AudioEncoder.mlmodelc`
- `TextDecoder.mlmodelc`
- `MelSpectrogram.mlmodelc`
- `tokenizer.json`, or a nested tokenizer under `models/openai/.../tokenizer.json`

Helpful commands:

- Cache a local preview model with `./scripts/download_whisperkit_preview_model.sh`
- Future Release installs will bundle any cached preview model found under `~/Library/Application Support/spk/WhisperKitModels`

Runtime rules:

- `spk` never downloads WhisperKit models at runtime.
- If no bundled, cached, or selected preview model exists, the app falls back to the normal non-streaming Whisper path.
