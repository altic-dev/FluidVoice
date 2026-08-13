# Local API

FluidVoice ships a small, **loopback-only** HTTP API that lets other apps and AI agents
running **on the same Mac** reuse its speech-to-text and text post-processing. This avoids
each agent bundling and loading its own ASR model — FluidVoice keeps one model warm and
serves transcription requests locally.

## Enabling

The API is **off by default**. Turn it on in `Settings → Local API (on-device agents)`.

You can also toggle it via `defaults`:

```bash
defaults write com.FluidApp.app LocalAPIEnabled -bool true
# optional custom port (default 47733):
defaults write com.FluidApp.app LocalAPIPort -int 47733
```

The Settings toggle starts/stops the server immediately. Setting the preference with `defaults`
while FluidVoice is running only writes the value — **relaunch FluidVoice** (or use the toggle) for
it to take effect, since the server is otherwise started only at app launch.

## Security

- The listener **refuses all non-loopback connections** — any non-local peer is rejected at
  accept time, before it can send a request — so the API is usable only from processes on this Mac.
- The API has **no authentication**. Loopback does not distinguish macOS login sessions: every local
  process that can connect may use every route, including reading transcription history and changing
  dictionary entries. Enable it only on a trusted Mac and turn it off when it is not needed.
- It is opt-in and off by default.
- Limits: request body **25 MB**; referenced OGG/Opus file **25 MB**; transcription audio
  **300 s (5 min)** per request. File-`path` input and inline OGG/Opus `audioBase64` input longer than
  the duration limit are **rejected**; other inline formats are currently **truncated to the first
  300 s**. These caps are independent — compressed audio can satisfy the byte limit yet still hit the
  duration limit.
- **Locality caveat:** `/v1/transcribe` runs fully on-device. `/v1/postprocess` runs your configured
  post-processing provider (Settings → AI Enhancement); if that provider is a remote API
  (OpenAI/Groq/Anthropic/…), the submitted text is sent there. Only the HTTP listener and transcription
  are guaranteed local.

## Endpoints

Base URL: `http://127.0.0.1:47733`

### `GET /v1/health`

Liveness probe. Returns `200 OK` when the server is running.

### `POST /v1/transcribe`

Transcribe an audio file with the currently selected speech model (reuses the already-loaded
model — no second instance).

Request body (JSON), one of:

```jsonc
{ "path": "/absolute/path/to/audio.ogg" }          // transcribe a file by path
{ "audioBase64": "<base64>", "filename": "clip.wav" } // or inline audio (extension hint)
```

Supported inputs include WAV, MP3, M4A, OGG/Opus and other common formats. OGG/Opus has an
embedded libopus fallback, so it does not depend on Homebrew, ffmpeg, or a system media extension.
The OGG fallback supports the mono/stereo Opus mapping used by Telegram voice messages; malformed,
chained, multiplexed, or other channel-mapped OGG streams return a clear `400` error.

Response:

```json
{
  "text": "the transcribed text",
  "confidence": 0.97,
  "sampleCount": 1402136,
  "provider": "Parakeet TDT v3 (Multilingual)"
}
```

### `POST /v1/postprocess`

Run FluidVoice's text post-processing/enhancement on a string.

```json
{ "text": "raw text to clean up" }
```

Response:

```json
{ "text": "cleaned text", "provider": "…", "model": "…" }
```

## Example integrations

Shell:

```bash
curl -s http://127.0.0.1:47733/v1/transcribe \
  -H 'Content-Type: application/json' \
  -d '{"path": "'"$PWD"'/memo.ogg"}' | jq -r .text
```

Python:

```python
import requests
r = requests.post("http://127.0.0.1:47733/v1/transcribe",
                  json={"path": "/tmp/memo.ogg"}, timeout=90)
print(r.json()["text"])
```

## Notes

- If the selected model is not resident yet, the first request loads it; subsequent requests
  are fast while it stays warm.
- Other endpoints exist for history and the custom dictionary (`GET /v1/history`,
  `GET|POST /v1/dictionary/*`); this document focuses on the ones most useful to agents.
