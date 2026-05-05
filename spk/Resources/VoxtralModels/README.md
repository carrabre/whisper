Bundled Voxtral Realtime model payloads are staged here for self-contained Release builds.

Expected staged folder:

- `Voxtral-Mini-4B-Realtime-2602/`

Release packaging copies the maintained local payload into this folder before the
signed app is built, then the app provisions the managed copy into:

- `~/Library/Application Support/spk/VoxtralModels/Voxtral-Mini-4B-Realtime-2602`

Do not commit the staged model payload to git.
