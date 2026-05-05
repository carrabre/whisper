Bundled WhisperKit live-preview model folders live here.

Current repo contents:

- `WHISPERKIT_MODELS.md`
- A staged `openai_whisper-medium/` payload during self-contained Release packaging

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

`spk` uses `openai_whisper-medium` as the only supported WhisperKit live-preview model.

Helpful commands:

- Cache a local preview model with `./scripts/download_whisperkit_preview_model.sh`
- Stage the bundled self-contained realtime payloads with `./scripts/stage_self_contained_realtime_assets.sh --resource-root spk/Resources`

Runtime rules:

- Live preview is currently Apple-Silicon-only.
- `spk` never downloads WhisperKit models at runtime.
- Self-contained Release installs provision the bundled payload into `~/Library/Application Support/spk/WhisperKitModels/openai_whisper-medium` on first launch.
- If no bundled, cached, or selected preview model exists, the app falls back to the normal non-streaming Whisper path.
- The final inserted transcript still uses Whisper, not WhisperKit.
