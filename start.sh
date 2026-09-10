#!/bin/sh
set -eu

: "${TZ:=Europe/Zurich}"

# Spotify / Librespot. PulseAudio is deliberate here: PulseAudio owns the
# Inferno ALSA device permanently, while Librespot can connect/disconnect from
# PulseAudio without destroying the Dante transmitter.
BACKEND="pulseaudio"
DEVICE=""
: "${DEVICE_NAME:=Spotify Dante}"
: "${DEVICE_TYPE:=speaker}"
: "${BITRATE:=320}"
: "${FORMAT:=S32}"
: "${INITIAL_VOLUME:=100}"
: "${ENABLE_SYSTEM_CACHE:=Y}"
: "${ZEROCONF_BACKEND:=libmdns}"
: "${PUID:=1000}"
: "${PGID:=1000}"

# Inferno / Dante settings.
DANTE_NAME="${DANTE_NAME:-${INFERNO_NAME:-${DEVICE_NAME}}}"
BIND_IP="${BIND_IP:-${INFERNO_BIND_IP:-}}"
SAMPLE_RATE="${SAMPLE_RATE:-${INFERNO_SAMPLE_RATE:-48000}}"
TX_CHANNELS="${TX_CHANNELS:-${INFERNO_TX_CHANNELS:-1}}"
RX_CHANNELS="${RX_CHANNELS:-${INFERNO_RX_CHANNELS:-0}}"
PROCESS_ID="${PROCESS_ID:-${INFERNO_PROCESS_ID:-90}}"
ALT_PORT="${ALT_PORT:-${INFERNO_ALT_PORT:-15800}}"
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
    echo "FEHLER: Dieses Image ist fuer genau einen Dante-TX-Kanal (Mono) ausgelegt."
    exit 1
fi

# Make sure uid/gid 1000 exists. Usually Dockerfile already created it.
if ! getent group "${PGID}" >/dev/null 2>&1; then
    groupadd -g "${PGID}" librespot-group
fi
if ! getent passwd "${PUID}" >/dev/null 2>&1; then
    useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash librespot-user
fi

PULSE_USER="$(getent passwd "${PUID}" | cut -d: -f1)"
PULSE_HOME="$(getent passwd "${PUID}" | cut -d: -f6)"
PULSE_RUNTIME="/run/user/${PUID}"
PULSE_SOCKET="${PULSE_RUNTIME}/pulse/native"

mkdir -p "${TMPDIR}" "${PULSE_RUNTIME}/pulse" "${PULSE_HOME}/.local/state/inferno_aoip"
chown -R "${PUID}:${PGID}" "${TMPDIR}" "${PULSE_RUNTIME}" "${PULSE_HOME}/.local"
chmod 700 "${PULSE_RUNTIME}"

DEVICE_ID_LINE=""
if [ -n "${DEVICE_ID}" ]; then
    DEVICE_ID_LINE="    DEVICE_ID \"${DEVICE_ID}\""
fi

# PulseAudio opens this PCM directly at 48 kHz mono. PulseAudio itself does
# the 44.1 -> 48 kHz conversion and stereo -> mono mixing for Spotify.
echo "Erzeuge /etc/asound.conf..."
cat > /etc/asound.conf <<EOF_ALSA
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

# Minimal PulseAudio setup. Crucially, module-suspend-on-idle is NOT loaded.
# Therefore module-alsa-sink keeps inferno_raw open even with no Spotify audio.
mkdir -p /etc/pulse
cat > /etc/pulse/dante.pa <<EOF_PULSE
.nofail
load-module module-native-protocol-unix socket=${PULSE_SOCKET} auth-anonymous=1
load-module module-alsa-sink sink_name=dante_sink device=inferno_raw rate=${SAMPLE_RATE} format=s32le channels=1 channel_map=mono tsched=0
set-default-sink dante_sink
EOF_PULSE

cat > /etc/pulse/daemon.conf <<EOF_DAEMON
daemonize = no
exit-idle-time = -1
default-sample-format = s32le
default-sample-rate = ${SAMPLE_RATE}
alternate-sample-rate = ${SAMPLE_RATE}
default-sample-channels = 1
resample-method = speex-float-5
EOF_DAEMON

# The upstream launcher creates this too, but write it in advance so the
# connection is deterministic and points to our in-container PulseAudio.
cat > /etc/pulse/client.conf <<EOF_CLIENT
default-server = unix:${PULSE_SOCKET}
autospawn = no
daemon-binary = /bin/true
enable-shm = false
EOF_CLIENT

export TZ BACKEND DEVICE DEVICE_NAME DEVICE_TYPE BITRATE FORMAT \
       INITIAL_VOLUME ENABLE_SYSTEM_CACHE ZEROCONF_BACKEND PUID PGID

echo
echo "===== Spotify / Dante ====="
echo "Spotify Name:      ${DEVICE_NAME}"
echo "Librespot Backend: ${BACKEND}"
echo "Dante Name:        ${DANTE_NAME}"
echo "Sample Rate:       ${SAMPLE_RATE}"
echo "Bind IP/Interface: ${BIND_IP}"
echo "TX Channels:       ${TX_CHANNELS}"
echo "RX Channels:       ${RX_CHANNELS}"
echo "Process ID:        ${PROCESS_ID}"
echo "ALT Port:          ${ALT_PORT}"
echo "Clock Path:        ${CLOCK_PATH}"
echo "Pulse user:        ${PULSE_USER} (${PUID}:${PGID})"
echo "Pulse socket:      ${PULSE_SOCKET}"
echo "==========================="
echo

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

echo "Starte PulseAudio -> Inferno dauerhaft..."

# Run PulseAudio as the same user the upstream librespot launcher uses for its
# PulseAudio backend. No suspend-on-idle module is loaded, so dante_sink owns
# inferno_raw for the full lifetime of the container.
su -s /bin/sh "${PULSE_USER}" -c \
    "HOME='${PULSE_HOME}' XDG_RUNTIME_DIR='${PULSE_RUNTIME}' TMPDIR='${TMPDIR}' pulseaudio --daemonize=no --exit-idle-time=-1 --log-target=stderr --log-level=notice --file=/etc/pulse/dante.pa" &
PULSE_PID=$!

# Wait up to 10 seconds for the PulseAudio socket and sink.
i=0
while [ ! -S "${PULSE_SOCKET}" ] && [ "${i}" -lt 10 ]; do
    if ! kill -0 "${PULSE_PID}" 2>/dev/null; then
        echo "FEHLER: PulseAudio wurde beendet, bevor der Socket bereit war."
        wait "${PULSE_PID}" || true
        exit 1
    fi
    i=$((i + 1))
    sleep 1
done

if [ ! -S "${PULSE_SOCKET}" ]; then
    echo "FEHLER: PulseAudio Socket wurde nicht erstellt: ${PULSE_SOCKET}"
    exit 1
fi

# Confirm that our permanent Dante sink exists.
if ! PULSE_SERVER="unix:${PULSE_SOCKET}" pactl list short sinks; then
    echo "FEHLER: PulseAudio laeuft, aber dante_sink konnte nicht abgefragt werden."
    exit 1
fi

if ! PULSE_SERVER="unix:${PULSE_SOCKET}" pactl list short sinks | grep -q '[[:space:]]dante_sink[[:space:]]'; then
    echo "FEHLER: PulseAudio dante_sink wurde nicht erstellt."
    exit 1
fi

echo "PulseAudio Dante-Sink ist aktiv und haelt Inferno dauerhaft offen."
echo "Starte Librespot..."

cd /app/bin
exec /app/bin/run-librespot.sh
