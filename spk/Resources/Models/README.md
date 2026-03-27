Place an optional bundled Whisper model here as one of:

`ggml-base.en-q5_1.bin`
`ggml-base-q5_1.bin`
`ggml-silero-v6.2.0.bin`

This folder is for the app's single Whisper pipeline.

- Runtime cache defaults to the preferred low-latency base model under `~/Library/Application Support/spk/Models/`
- `./scripts/download_whisper_model.sh --cache` downloads the preferred Whisper model and the local VAD model into the runtime cache
- `./scripts/download_whisper_model.sh --bundle` downloads the preferred Whisper model and the local VAD model here so future builds embed them
- `./scripts/download_whisper_model.sh --model <id>` overrides the model id, for example `base-q5_1` or `large-v3-turbo-q5_0`
- `spk` never downloads models at runtime; if neither the cache nor bundle copy exists, launch will fail until local model files are installed
- `./scripts/install_release.sh --development-team <TEAM_ID>` and `./scripts/run_dev.sh` prefetch the Whisper cache by default
