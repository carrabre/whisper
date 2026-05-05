Bundled Voxtral Realtime runtime payloads are staged here for self-contained Release builds.

Expected staged folder:

- `py312/`
- `voxtral_strict_preview_smoke_test.wav`

Release packaging copies the maintained local runtime into this folder before the
signed app is built, then the app provisions the managed copy into:

- `~/Library/Application Support/spk/VoxtralRuntime/py312`

The bundled smoke-test WAV lets spk perform strict startup validation for Voxtral
live preview before enabling realtime insertion.

Do not commit the staged runtime payload to git.
