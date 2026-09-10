FROM rust:1.92.0-slim-trixie AS inferno-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libasound2-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG INFERNO_REF=dev

RUN git clone --recurse-submodules https://github.com/teodly/inferno.git . && \
    git checkout "${INFERNO_REF}" && \
    git submodule update --init --recursive

ENV RUSTFLAGS="-C target-feature=-crt-static"

RUN mkdir /out && \
    cargo build --release -p alsa_pcm_inferno && \
    cp target/release/libasound_module_pcm_inferno.so /out/


# Librespot runtime. The upstream image already contains a librespot binary
# compiled with ALSA + PulseAudio + libmdns support.
FROM giof71/librespot:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    tzdata \
    pulseaudio \
    pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=inferno-builder \
    /out/libasound_module_pcm_inferno.so \
    /opt/inferno/libasound_module_pcm_inferno.so

RUN set -eux; \
    ALSA_LIB_PATH="$(ldconfig -p | awk '/libasound\.so\.2 / {print $NF; exit}')"; \
    test -n "${ALSA_LIB_PATH}"; \
    ALSA_PLUGIN_DIR="$(dirname "${ALSA_LIB_PATH}")/alsa-lib"; \
    mkdir -p "${ALSA_PLUGIN_DIR}"; \
    cp /opt/inferno/libasound_module_pcm_inferno.so "${ALSA_PLUGIN_DIR}/"; \
    chmod 644 "${ALSA_PLUGIN_DIR}/libasound_module_pcm_inferno.so"; \
    \
    # The upstream librespot launcher runs PulseAudio mode as uid/gid 1000.
    # Create that account now so both our PulseAudio server and librespot use
    # the same predictable user and runtime directory.
    if ! getent group 1000 >/dev/null; then groupadd -g 1000 librespot-user; fi; \
    if ! getent passwd 1000 >/dev/null; then \
        useradd -m -u 1000 -g 1000 -s /bin/bash librespot-user; \
    fi

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/bin/start.sh"]
