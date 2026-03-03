FROM ghcr.io/platformio/platformio-core:6.1.16

WORKDIR /workspace

COPY platformio.ini ./

# Pre-install platform + board packages so pio build layer is fast.
# Must run before COPY src/ so that source changes do not invalidate this cache layer.
RUN pio pkg install

# Copy source after dependency installation to preserve Docker layer cache.
# lib/ and include/ contain only PlatformIO README placeholders — no source files to copy.
COPY src/ ./src/

VOLUME ["/workspace/.pio"]

CMD ["pio", "run"]
