Bundled Whisper assets for `spk` live here.

Current default preferences:

- `ggml-base.en-q5_1.bin`
- `ggml-silero-v6.2.0.bin`

Final transcription resolution order:

1. Bundled preferred Whisper model in this folder
2. `SPK_WHISPER_MODEL_PATH`
3. Local cache under `~/Library/Application Support/spk/Models`

VAD resolution order:

1. Bundled `ggml-silero-v6.2.0.bin`
2. `SPK_WHISPER_VAD_MODEL_PATH`
3. Local cache under `~/Library/Application Support/spk/Models`

Notes:

- `spk` prefers `ggml-base.en-q5_1.bin` on English-first Macs and `ggml-base-q5_1.bin` otherwise
- `SPK_WHISPER_MODEL` and `SPK_WHISPER_MODEL_PATH` may be used to point Whisper at another compatible local ggml model
- If no supported Whisper model is available locally, startup fails until a local model is installed
- If no local VAD model is available, transcription still runs, but without VAD assistance
- `spk` never downloads models at runtime

Helpful commands:

- `./scripts/download_whisper_model.sh --cache` downloads the preferred Whisper model and VAD model into the runtime cache
- `./scripts/download_whisper_model.sh --bundle` downloads the preferred Whisper model and VAD model here so future builds embed them
- `./scripts/download_whisper_model.sh --model <id>` overrides the Whisper model id
- `./scripts/install_release.sh --development-team <TEAM_ID>` bundles local Whisper assets into a signed Release install
- `./scripts/run_dev.sh` prefetches the Whisper cache by default unless `--skip-model-prefetch` is passed
