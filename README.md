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
FFmpeg bridge (kept running continuously)
      ↓
pcm.dante
      ↓
ALSA plug + stereo->mono route
      ↓
inferno_raw (48 kHz / mono)
      ↓
Inferno / Dante TX
```

`KEEP_DANTE_ALIVE=true` enables this mode. FFmpeg owns `pcm.dante`
continuously, so the Inferno device remains open even when Librespot stops
or pauses playback. The FIFO is held open across Spotify playback sessions.
A short digital-silence seed at container startup forces the ALSA/Inferno
path to open immediately.

Set `KEEP_DANTE_ALIVE=false` to return to the original direct Librespot ALSA
mode (`BACKEND=alsa`, `DEVICE=dante`).

The included TrueNAS example retains the working `AP_PORT=443` setting.
`DMIX_IPC_KEY` is no longer used and should be removed.
