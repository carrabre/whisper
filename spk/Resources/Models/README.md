Place an optional bundled Whisper model here as:

`ggml-medium.bin`

You usually do not need to manage this manually:

- `./scripts/download_whisper_model.sh` caches the model in `~/Library/Application Support/spk/Models`
- `./scripts/download_whisper_model.sh --bundle` downloads the model here so future app builds embed it
- if neither exists, spk downloads `ggml-medium.bin` automatically on first launch
