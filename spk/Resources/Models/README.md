Place an optional bundled Whisper model here as:

`ggml-medium.bin`

This folder is for the app's single Whisper pipeline.

- Runtime cache: `~/Library/Application Support/spk/Models/ggml-medium.bin`
- `./scripts/download_whisper_model.sh --cache` downloads the model into the runtime cache
- `./scripts/download_whisper_model.sh --bundle` downloads the model here so future builds embed it
- If neither the cache nor bundle copy exists, `spk` downloads `ggml-medium.bin` automatically on first launch
- `./scripts/install_release.sh --development-team <TEAM_ID>` and `./scripts/run_dev.sh` prefetch the Whisper cache by default
