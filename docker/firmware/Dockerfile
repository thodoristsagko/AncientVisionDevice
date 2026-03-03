FROM ghcr.io/platformio/platformio-core:latest

WORKDIR /workspace

# Copy firmware project files only (not app/ or docs/)
# lib/ and include/ contain only PlatformIO README placeholders — no source files to copy
COPY platformio.ini ./
COPY src/ ./src/

# Pre-install platform + board packages so builds are fast
RUN pio pkg install

# Default command: build firmware
CMD ["pio", "run"]
