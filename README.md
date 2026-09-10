# librespot-inferno

Spotify Connect to Dante using Librespot + Inferno.

## Persistent Dante mode

This build keeps the known-good ALSA/Inferno path and adds an optional
persistent bridge without PulseAudio, PipeWire or ALSA dmix.

```text
Spotify Connect
      ↓
Librespot pipe backend (S32 / 44.1 kHz / stereo)
      ↓
named FIFO
      ↓
the real-time PCM bridge bridge (kept running continuously)
      ↓
pcm.dante
      ↓
ALSA plug + stereo->mono route
      ↓
inferno_raw (48 kHz / mono)
      ↓
Inferno / Dante TX
```

`KEEP_DANTE_ALIVE=true` enables this mode. the real-time PCM bridge owns `pcm.dante`
continuously, so the Inferno device remains open even when Librespot stops
or pauses playback. The FIFO is held open across Spotify playback sessions.
A short digital-silence seed at container startup forces the ALSA/Inferno
path to open immediately.

Set `KEEP_DANTE_ALIVE=false` to return to the original direct Librespot ALSA
mode (`BACKEND=alsa`, `DEVICE=dante`).

The included TrueNAS example retains the working `AP_PORT=443` setting.
`DMIX_IPC_KEY` is no longer used and should be removed.


## Keepalive v2: immediate stop

When `KEEP_DANTE_ALIVE=true`, librespot uses its pipe backend, but the pipe is
consumed by `pcm_keepalive.py` at the actual ALSA playback rate. If Spotify is
paused, stopped, or disconnected, the bridge immediately substitutes digital
silence while keeping the `dante` ALSA device (and therefore Inferno) open.
This avoids the large audio read-ahead that can happen with a generic FFmpeg
pipe bridge.

Optional tuning variables:

- `KEEPALIVE_CHUNK_MS` (default `10`)
- `KEEPALIVE_PIPE_BYTES` (default `4096`)

Normally neither needs to be set in TrueNAS.
