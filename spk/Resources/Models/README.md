Bundled Whisper assets for `spk` live here.

Current repo defaults:

- `ggml-base.en-q5_1.bin`
- `ggml-silero-v6.2.0.bin`

Final transcription resolution order:

1. Bundled Whisper model in this folder
2. `SPK_WHISPER_MODEL_PATH`
3. Local cache under `~/Library/Application Support/spk/Models`

VAD resolution order:

1. Bundled `ggml-silero-v6.2.0.bin`
2. `SPK_WHISPER_VAD_MODEL_PATH`
3. Local cache under `~/Library/Application Support/spk/Models`

Notes:

- On English-language systems, `spk` prefers `ggml-base.en-q5_1.bin` by default; otherwise it prefers `ggml-base-q5_1.bin`
- Other supported local `ggml-*.bin` Whisper models can also be used, including script-downloaded overrides such as `base-q5_1` or `large-v3-turbo-q5_0`
- If no supported Whisper model is available locally, startup fails until a local model is installed
- If no local VAD model is available, transcription still runs, but without VAD assistance
- `spk` never downloads models at runtime

Helpful commands:

- `./scripts/download_whisper_model.sh --cache` downloads the preferred Whisper model and VAD model into the runtime cache
- `./scripts/download_whisper_model.sh --bundle` downloads the preferred Whisper model and VAD model here so future builds embed them
- `./scripts/download_whisper_model.sh --model <id>` overrides the Whisper model id
- `./scripts/install_release.sh --development-team <TEAM_ID>` bundles local Whisper assets into a signed Release install
- `./scripts/run_dev.sh` prefetches the Whisper cache by default unless `--skip-model-prefetch` is passed
