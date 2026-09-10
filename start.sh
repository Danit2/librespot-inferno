#!/bin/sh
set -eu

: "${TZ:=Europe/Zurich}"

# Librespot defaults. DEVICE=dante is important: this is the ALSA "plug"
# device, which can convert Spotify's stream to the fixed Dante rate.
: "${BACKEND:=alsa}"
: "${DEVICE:=dante}"
: "${DEVICE_NAME:=Spotify Dante}"
: "${DEVICE_TYPE:=speaker}"
: "${BITRATE:=320}"
: "${FORMAT:=S32}"
: "${INITIAL_VOLUME:=100}"
: "${ENABLE_SYSTEM_CACHE:=Y}"
: "${ZEROCONF_BACKEND:=libmdns}"

# Keep Inferno/Dante advertised even while Librespot is idle.
: "${KEEP_DANTE_ALIVE:=true}"
: "${DMIX_IPC_KEY:=59090}"

# Export defaults so GioF71's original /app/bin/run-librespot.sh sees them.
export TZ BACKEND DEVICE DEVICE_NAME DEVICE_TYPE BITRATE FORMAT \
       INITIAL_VOLUME ENABLE_SYSTEM_CACHE ZEROCONF_BACKEND

# Inferno / Dante settings. Old and new variable names are supported,
# matching the existing squeezelite-inferno container as closely as possible.
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

if [ -z "${BIND_IP}" ]; then
    echo "FEHLER: BIND_IP oder INFERNO_BIND_IP ist nicht gesetzt."
    exit 1
fi

if [ "${TX_CHANNELS}" -ne 1 ]; then
    echo "FEHLER: Dieses Image ist aktuell fuer genau einen Dante-TX-Kanal (Mono) ausgelegt."
    echo "       INFERNO_TX_CHANNELS muss 1 sein."
    exit 1
fi

DEVICE_ID_LINE=""
if [ -n "${DEVICE_ID}" ]; then
    DEVICE_ID_LINE="    DEVICE_ID \"${DEVICE_ID}\""
fi

echo "Erzeuge /etc/asound.conf..."
cat > /etc/asound.conf <<EOF_ALSA
# Librespot opens this device. The plug layer handles Spotify's input format
# and sample rate and feeds the stereo->mono route below.
pcm.dante {
    type plug
    slave.pcm "dante_mono"

    hint {
        show on
        description "Spotify to mono Dante output via Inferno"
    }
}

# Stereo L/R -> one Dante channel. Its slave is dmix, not Inferno directly,
# so Librespot and the permanent silence keepalive can share the transmitter.
pcm.dante_mono {
    type route
    slave.pcm "dante_mix"
    slave.channels 1

    ttable.0.0 0.5
    ttable.1.0 0.5
}

# Shared, fixed-format playback PCM. The first client opens inferno_raw and
# dmix keeps that slave open while at least one client remains connected.
pcm.dante_mix {
    type dmix
    ipc_key ${DMIX_IPC_KEY}
    ipc_key_add_uid true
    ipc_perm 0666

    slave {
        pcm "inferno_raw"
        format S32_LE
        rate ${SAMPLE_RATE}
        channels 1
        period_time 10000
        buffer_time 40000
    }

    bindings {
        0 0
    }

    hint {
        show on
        description "Shared 48 kHz mono Dante mixer"
    }
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

echo "Verwendete /etc/asound.conf:"
cat /etc/asound.conf

echo
echo "===== Spotify / Dante ====="
echo "Spotify Name:      ${DEVICE_NAME}"
echo "Librespot Backend: ${BACKEND}"
echo "ALSA Device:       ${DEVICE}"
echo "Dante Name:        ${DANTE_NAME}"
echo "Sample Rate:       ${SAMPLE_RATE}"
echo "Bind IP/Interface: ${BIND_IP}"
echo "TX Channels:       ${TX_CHANNELS}"
echo "RX Channels:       ${RX_CHANNELS}"
echo "Process ID:        ${PROCESS_ID}"
echo "ALT Port:          ${ALT_PORT}"
echo "Clock Path:        ${CLOCK_PATH}"
echo "Dante Keepalive:   ${KEEP_DANTE_ALIVE}"
echo "DMIX IPC key:      ${DMIX_IPC_KEY}"
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

if [ "${KEEP_DANTE_ALIVE}" = "true" ]; then
    echo "Starte permanenten Dante-Silence-Keepalive..."

    # /dev/zero never reaches EOF. This keeps one dmix client open forever,
    # which in turn keeps inferno_raw open and the Dante device advertised.
    aplay -q \
        -D dante_mix \
        -t raw \
        -f S32_LE \
        -r "${SAMPLE_RATE}" \
        -c 1 \
        /dev/zero &

    KEEPALIVE_PID=$!
    sleep 1

    if ! kill -0 "${KEEPALIVE_PID}" 2>/dev/null; then
        echo "FEHLER: Dante-Silence-Keepalive konnte nicht gestartet werden."
        exit 1
    fi

    echo "Dante-Silence-Keepalive aktiv (PID ${KEEPALIVE_PID})."
fi

echo "Starte Librespot..."

# Keep all Spotify Connect, cache and Zeroconf handling from the upstream
# giof71/librespot image.
cd /app/bin
exec /app/bin/run-librespot.sh
