Place an optional bundled Whisper model here as:

`ggml-medium.bin`

This folder is only for the multilingual Whisper fallback mode.

- Both runtime caches live under the same parent root: `~/Library/Application Support/spk/Models`
- `./scripts/download_whisper_model.sh` caches the model in `~/Library/Application Support/spk/Models`
- `./scripts/download_whisper_model.sh --bundle` downloads the model here so future app builds embed it
- if neither exists, spk downloads `ggml-medium.bin` automatically on first launch
- `./scripts/install_release.sh --development-team <TEAM_ID>` and `./scripts/run_dev.sh` now prefetch both the Whisper cache and the default Nemotron cache by default
- the default English realtime mode does not bundle its assets here; it downloads the upstream Hugging Face `.nemo` checkpoint and stages a local checkpoint-backed runtime into `~/Library/Application Support/spk/Models/nemotron-en/<version>`
- the installer and dev helper also create the managed Python runtime that the Nemotron English backend uses at launch
