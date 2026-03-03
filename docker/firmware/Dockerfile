FROM python:3.11-slim

# Install PlatformIO and build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    pip install --no-cache-dir platformio==6.1.16 && \
    rm -rf /var/lib/apt/lists/*

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
