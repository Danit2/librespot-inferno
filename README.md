# librespot-inferno

One Docker container provides one Spotify Connect player and one Inferno Dante transmitter.

## Signal path

```text
Spotify Connect
      ↓
Librespot
      ↓
pcm.dante (ALSA plug; rate/format conversion)
      ↓
pcm.dante_mono (stereo L/R -> mono)
      ↓
pcm.dante_mix (ALSA dmix, fixed 48 kHz/S32/mono)
      ↓
pcm.inferno_raw
      ↓
Inferno
      ↓
Dante TX, 1 channel
```

A permanent `aplay` process writes digital silence to `pcm.dante_mix`. This keeps
`inferno_raw` open even when Librespot is idle, so the Dante transmitter remains
advertised and available in Dante Controller / NetAudio all the time.

Librespot shares the same `dmix` PCM and is mixed with the zero-valued keepalive
stream when Spotify playback starts.

## Keepalive settings

```yaml
KEEP_DANTE_ALIVE: 'true'
DMIX_IPC_KEY: '59090'
```

`KEEP_DANTE_ALIVE=true` is the default. Set it to `false` to restore the old
behavior where Inferno is opened only while Librespot is playing.

The `DMIX_IPC_KEY` only identifies this ALSA dmix instance. Keep it unique if
multiple dmix PCMs are ever placed in the same IPC namespace.

## Important settings

- `network_mode: host` is used for Spotify Connect discovery and Dante networking.
- `DEVICE=dante` must be used, not `inferno_raw`.
- Inferno is fixed to 48 kHz and one TX channel in this image.
- `INFERNO_BIND_IP` may be an interface name or the dedicated IP address assigned to this Inferno player.
- `INFERNO_DEVICE_ID`, `INFERNO_PROCESS_ID` and `INFERNO_ALT_PORT` must stay unique.
- `/mnt/app/inferno-shared:/shared` shares the existing `usrvclock` PTP clock.
- `/data/system-cache` persists the Spotify Connect system cache.

## Build

The included GitHub Actions workflow publishes the image to:

```text
ghcr.io/<github-user>/librespot-inferno:latest
```

For `Danit2/librespot-inferno` this is:

```text
ghcr.io/danit2/librespot-inferno:latest
```
