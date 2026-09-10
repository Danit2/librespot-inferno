#!/usr/bin/env python3
"""Real-time FIFO -> ALSA keepalive bridge for librespot.

Reads raw S32_LE stereo PCM from librespot's pipe at audio-device pace.
When no Spotify samples are available, writes digital silence instead.
This keeps the ALSA/Inferno device permanently open without buffering a song
far ahead of real time.
"""

import errno
import fcntl
import os
import signal
import subprocess
import sys

fifo_path = os.environ.get("SPOTIFY_PIPE_PATH", "/shared/tmp_spotify/librespot.raw")
alsa_device = os.environ.get("KEEPALIVE_ALSA_DEVICE", "dante")
rate = int(os.environ.get("SPOTIFY_PIPE_RATE", "44100"))
channels = 2
sample_bytes = 4  # S32_LE
chunk_ms = int(os.environ.get("KEEPALIVE_CHUNK_MS", "10"))
pipe_bytes = int(os.environ.get("KEEPALIVE_PIPE_BYTES", "4096"))

frames_per_chunk = max(1, rate * chunk_ms // 1000)
chunk_bytes = frames_per_chunk * channels * sample_bytes
silence = bytes(chunk_bytes)

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGHUP, stop)

# O_RDWR keeps the FIFO alive across librespot pause/stop/reconnect cycles.
# O_NONBLOCK lets us substitute silence immediately if Spotify has no samples.
fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)

# Keep the FIFO deliberately small. This limits stale audio after a Spotify
# pause/stop to only a few milliseconds instead of allowing large read-ahead.
try:
    fcntl.fcntl(fd, fcntl.F_SETPIPE_SZ, pipe_bytes)
except (AttributeError, OSError):
    pass

cmd = [
    "aplay", "-q",
    "-D", alsa_device,
    "-t", "raw",
    "-f", "S32_LE",
    "-r", str(rate),
    "-c", str(channels),
]

print(
    f"Realtime-Bridge: FIFO={fifo_path}, ALSA={alsa_device}, "
    f"{rate} Hz stereo S32_LE, chunk={chunk_ms} ms",
    flush=True,
)

aplay = subprocess.Popen(cmd, stdin=subprocess.PIPE, bufsize=0)
assert aplay.stdin is not None
out_fd = aplay.stdin.fileno()

# Also keep the pipe feeding aplay small, so there is little queued audio
# between this bridge and ALSA.
try:
    fcntl.fcntl(out_fd, fcntl.F_SETPIPE_SZ, pipe_bytes)
except (AttributeError, OSError):
    pass

try:
    while running:
        if aplay.poll() is not None:
            raise RuntimeError(f"aplay exited unexpectedly with code {aplay.returncode}")

        buf = bytearray()
        while len(buf) < chunk_bytes:
            try:
                part = os.read(fd, chunk_bytes - len(buf))
                if not part:
                    break
                buf.extend(part)
            except BlockingIOError:
                break
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    break
                raise

        if len(buf) < chunk_bytes:
            buf.extend(silence[: chunk_bytes - len(buf)])

        view = memoryview(buf)
        while view and running:
            try:
                written = os.write(out_fd, view)
                view = view[written:]
            except BrokenPipeError:
                raise RuntimeError("aplay input pipe closed")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        aplay.stdin.close()
    except Exception:
        pass
    if aplay.poll() is None:
        aplay.terminate()
        try:
            aplay.wait(timeout=2)
        except subprocess.TimeoutExpired:
            aplay.kill()
            aplay.wait()
