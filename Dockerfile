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


# Librespot runtime including Spotify Connect / Zeroconf handling.
# We add only the Inferno ALSA plugin and our startup wrapper.
FROM giof71/librespot:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    tzdata \
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
    ls -l "${ALSA_PLUGIN_DIR}/libasound_module_pcm_inferno.so"

COPY asound.conf /etc/asound.conf
COPY start.sh /usr/local/bin/start.sh

RUN chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start.sh"]
