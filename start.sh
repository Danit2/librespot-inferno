#!/bin/sh
set -eu

: "${TZ:=Europe/Zurich}"

# Normal mode stays identical to the known-good setup.
: "${BACKEND:=alsa}"
: "${DEVICE:=dante}"
: "${DEVICE_NAME:=Spotify Dante}"
: "${DEVICE_TYPE:=speaker}"
: "${BITRATE:=320}"
: "${FORMAT:=S32}"
: "${INITIAL_VOLUME:=100}"
: "${ENABLE_SYSTEM_CACHE:=Y}"
: "${ZEROCONF_BACKEND:=libmdns}"

# Optional persistent Dante mode.
# Instead of opening Inferno directly from Librespot, Librespot writes raw
# S32/44.1-kHz stereo to a FIFO. FFmpeg owns the existing ALSA "dante"
# device permanently. This keeps Inferno (and therefore the Dante device)
# open between Spotify playback sessions.
: "${KEEP_DANTE_ALIVE:=false}"
: "${SPOTIFY_PIPE_RATE:=44100}"
: "${FFMPEG_LOGLEVEL:=warning}"

# Inferno / Dante settings.
DANTE_NAME="${DANTE_NAME:-${INFERNO_NAME:-${DEVICE_NAME}}}"
BIND_IP="${BIND_IP:-${INFERNO_BIND_IP:-}}"
SAMPLE_RATE="${SAMPLE_RATE:-${INFERNO_SAMPLE_RATE:-48000}}"
TX_CHANNELS="${TX_CHANNELS:-${INFERNO_TX_CHANNELS:-1}}"
RX_CHANNELS="${RX_CHANNELS:-${INFERNO_RX_CHANNELS:-0}}"
PROCESS_ID="${PROCESS_ID:-${INFERNO_PROCESS_ID:-90}}"
ALT_PORT="${ALT_PORT:-${INFERNO_ALT_PORT:-16000}}"
CLOCK_PATH="${CLOCK_PATH:-${INFERNO_CLOCK_PATH:-${CLOCK_SOCKET:-/shared/usrvclock}}}"
TMPDIR="${TMPDIR:-/shared/tmp_spotify}"
CLOCK_STARTUP_DELAY="${CLOCK_STARTUP_DELAY:-20}"
TX_LATENCY_NS="${TX_LATENCY_NS:-${INFERNO_TX_LATENCY_NS:-10000000}}"
RX_LATENCY_NS="${RX_LATENCY_NS:-${INFERNO_RX_LATENCY_NS:-10000000}}"
DEVICE_ID="${DEVICE_ID:-${INFERNO_DEVICE_ID:-}}"
WAIT_FOR_CLOCK="${WAIT_FOR_CLOCK:-true}"
SPOTIFY_PIPE_PATH="${SPOTIFY_PIPE_PATH:-${TMPDIR}/librespot.raw}"

if [ -z "${BIND_IP}" ]; then
    echo "FEHLER: BIND_IP oder INFERNO_BIND_IP ist nicht gesetzt."
    exit 1
fi

DEVICE_ID_LINE=""
if [ -n "${DEVICE_ID}" ]; then
    DEVICE_ID_LINE="    DEVICE_ID \"${DEVICE_ID}\""
fi

echo "Erzeuge /etc/asound.conf..."
cat > /etc/asound.conf <<EOF_ALSA
pcm.dante {
    type plug
    slave.pcm "dante_mono"

    hint {
        show on
        description "Spotify to mono Dante output via Inferno"
    }
}

pcm.dante_mono {
    type route
    slave.pcm "inferno_raw"
    slave.channels 1

    # Spotify stereo L/R -> Dante mono (50 % + 50 %)
    ttable.0.0 0.5
    ttable.1.0 0.5
}

pcm.inferno_raw {
    type inferno

    NAME "${DANTE_NAME}"
    SAMPLE_RATE "${SAMPLE_RATE}"

    TX_CHANNELS ${TX_CHANNELS}
    RX_CHANNELS ${RX_CHANNELS}

    BIND_IP "${BIND_IP}"
${DEVICE_ID_LINE}
    PROCESS_ID ${PROCESS_ID}
    ALT_PORT ${ALT_PORT}

    CLOCK_PATH "${CLOCK_PATH}"

    TX_LATENCY_NS ${TX_LATENCY_NS}
    RX_LATENCY_NS ${RX_LATENCY_NS}

    hint {
        show on
        description "Raw Inferno Dante PCM"
    }
}
EOF_ALSA

echo
echo "===== Spotify / Dante ====="
echo "Spotify Name:      ${DEVICE_NAME}"
echo "Configured Backend:${BACKEND}"
echo "ALSA Device:       ${DEVICE}"
echo "Dante Name:        ${DANTE_NAME}"
echo "Sample Rate:       ${SAMPLE_RATE}"
echo "Bind IP/Interface: ${BIND_IP}"
echo "TX Channels:       ${TX_CHANNELS}"
echo "RX Channels:       ${RX_CHANNELS}"
echo "Process ID:        ${PROCESS_ID}"
echo "ALT Port:          ${ALT_PORT}"
echo "Clock Path:        ${CLOCK_PATH}"
echo "Keep Dante alive:  ${KEEP_DANTE_ALIVE}"
echo "==========================="
echo

mkdir -p "${TMPDIR}"
rm -f "${TMPDIR}"/usrvclock-client.* 2>/dev/null || true

if [ "${WAIT_FOR_CLOCK}" = "true" ]; then
    echo "Warte auf Clock-Socket: ${CLOCK_PATH}"

    while [ ! -S "${CLOCK_PATH}" ]; do
        echo "warte auf ${CLOCK_PATH}..."
        sleep 1
    done

    echo "Clock-Socket gefunden: ${CLOCK_PATH}"
    ls -la "${CLOCK_PATH}" || true

    echo "Warte ${CLOCK_STARTUP_DELAY}s auf PTP-Sync..."
    sleep "${CLOCK_STARTUP_DELAY}"
fi

# Direct mode: exactly the old working ALSA behavior.
if [ "${KEEP_DANTE_ALIVE}" != "true" ]; then
    echo "Starte Librespot direkt ueber ALSA..."
    export TZ BACKEND DEVICE DEVICE_NAME DEVICE_TYPE BITRATE FORMAT \
           INITIAL_VOLUME ENABLE_SYSTEM_CACHE ZEROCONF_BACKEND
    cd /app/bin
    exec /app/bin/run-librespot.sh
fi

# Persistent mode. Librespot writes raw S32/44.1-kHz stereo to a FIFO.
# A small real-time bridge owns ALSA "dante" permanently. It reads only at
# audio-device speed and inserts digital silence whenever Spotify is paused,
# stopped or disconnected. This prevents the large read-ahead that occurred
# with FFmpeg while keeping Inferno continuously open.
echo "Starte getakteten persistenten ALSA-Dante-Bridge..."

rm -f "${SPOTIFY_PIPE_PATH}"
mkfifo "${SPOTIFY_PIPE_PATH}"
chmod 0666 "${SPOTIFY_PIPE_PATH}"

export SPOTIFY_PIPE_PATH
export KEEPALIVE_ALSA_DEVICE="${DEVICE}"
export SPOTIFY_PIPE_RATE

/usr/local/bin/pcm_keepalive.py &
BRIDGE_PID=$!
sleep 1

if ! kill -0 "${BRIDGE_PID}" 2>/dev/null; then
    echo "FEHLER: Getakteter ALSA-Dante-Bridge ist beim Start beendet worden."
    wait "${BRIDGE_PID}" 2>/dev/null || true
    exit 1
fi

echo "ALSA-Dante-Bridge aktiv (PID ${BRIDGE_PID})."
echo "Inferno bleibt offen; bei Spotify-Pause/Stop wird sofort Stille gesendet."

# For Librespot only, switch to the officially supported pipe backend.
# All Spotify Connect/cache/AP/Zeroconf logic still comes from GioF71's
# original run-librespot.sh. AP_PORT=443 etc. remain untouched.
BACKEND=pipe
DEVICE="${SPOTIFY_PIPE_PATH}"
FORMAT=S32
export TZ BACKEND DEVICE DEVICE_NAME DEVICE_TYPE BITRATE FORMAT \
       INITIAL_VOLUME ENABLE_SYSTEM_CACHE ZEROCONF_BACKEND

LIBRESPOT_PID=""
cleanup() {
    set +e
    if [ -n "${LIBRESPOT_PID}" ]; then
        kill "${LIBRESPOT_PID}" 2>/dev/null || true
    fi
    if [ -n "${BRIDGE_PID:-}" ]; then
        kill "${BRIDGE_PID}" 2>/dev/null || true
    fi
    rm -f "${SPOTIFY_PIPE_PATH}" 2>/dev/null || true
}
trap 'cleanup; exit 143' INT TERM HUP

echo "Starte Librespot (Pipe -> permanenter ALSA-Dante-Bridge)..."
cd /app/bin
/app/bin/run-librespot.sh &
LIBRESPOT_PID=$!

set +e
wait "${LIBRESPOT_PID}"
RC=$?
set -e

cleanup
exit "${RC}"
