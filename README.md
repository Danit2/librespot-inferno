# librespot-inferno

One Docker container provides one Spotify Connect player and one Inferno Dante transmitter.

## Signal path

```text
Spotify Connect
      ↓
Librespot (ALSA)
      ↓
pcm.dante (ALSA plug; rate/format conversion when required)
      ↓
pcm.dante_mono (stereo L/R -> mono)
      ↓
pcm.inferno_raw (fixed 48 kHz)
      ↓
Inferno
      ↓
Dante TX, 1 channel
```

The project is derived from the working `squeezelite-inferno` setup. The Dante/PTP side stays intentionally similar; Squeezelite is replaced with Librespot.

## Important settings

- `network_mode: host` is required for reliable Spotify Connect discovery.
- `DEVICE=dante` must be used, not `inferno_raw`: the `dante` ALSA `plug` device can convert the Librespot stream to Inferno's fixed 48 kHz rate.
- `INFERNO_BIND_IP=ens11f0` selects the Dante network interface used in the existing setup.
- `INFERNO_DEVICE_ID`, `INFERNO_PROCESS_ID` and `INFERNO_ALT_PORT` must be unique compared with every other Inferno instance on the same host.
- `/mnt/app/inferno-shared:/shared` shares the existing `usrvclock` PTP clock with this player.
- `/data/system-cache` is persisted so Librespot can retain its Spotify Connect system cache.

## Current example identity

The included `docker-compose.yml` uses:

```text
Spotify device name: Spotify Dante
Dante device name:   Spotify-Dante
Device ID:           0000020000009001
Process ID:          90
ALT port:            16000
Dante interface:     ens11f0
Sample rate:         48000 Hz
TX channels:         1 (mono)
```

Change the identity values if any of them are already used by another Inferno player.

## Build / GitHub Container Registry

The included GitHub Actions workflow builds `linux/amd64` and publishes automatically to:

```text
ghcr.io/<github-user>/librespot-inferno:latest
```

For the repository `Danit2/librespot-inferno`, this becomes:

```text
ghcr.io/danit2/librespot-inferno:latest
```

## TrueNAS

The included `docker-compose.yml` is already adapted to the existing TrueNAS/Inferno layout:

```text
/mnt/app/inferno-shared:/shared
ens11f0
/shared/usrvclock
```

Start it using the same Custom App / Compose method as the existing Squeezelite Inferno players.
