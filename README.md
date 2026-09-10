# librespot-inferno

Spotify Connect -> PulseAudio -> Inferno -> Dante.

## Why PulseAudio?

Librespot opens and closes its normal ALSA output depending on playback state.
That makes a directly attached Inferno Dante transmitter disappear while Spotify
is idle. ALSA `dmix` cannot be used here because `dmix` requires a direct/hardware
style slave and rejects the custom `type inferno` PCM.

This image therefore runs a small PulseAudio server inside the container:

```
Spotify/librespot
      |
      v
PulseAudio (48 kHz mono sink)
      |
      v
inferno_raw
      |
      v
Dante TX
```

PulseAudio's `module-suspend-on-idle` is deliberately not loaded. Therefore the
ALSA sink remains open and Inferno/Dante stays advertised even when Spotify is
paused or disconnected.

## Important TrueNAS settings

Use host networking and the shared usrvclock volume. Give the Spotify Dante
instance its own Inferno IP/device/process/port values, just as with the other
virtual Dante players.

The example compose uses:

- Dante IP: `169.254.10.19`
- Device ID: `0000020000001081`
- Process ID: `90`
- Alt port: `15800`
- Rate: `48000`
- TX channels: `1`

Adjust the IP if your final Dante alias plan differs.
