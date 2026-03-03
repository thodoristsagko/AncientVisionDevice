FROM python:3.11-slim

# Install Docker CLI so run_pipeline.py can trigger docker compose run --rm flutter
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Copy requirements first so the pip install layer is cached
# independently of script changes.
COPY docker/ml/requirements.txt ./requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

# Copy training scripts.
COPY scripts/ ./scripts/

# Default command: run both training scripts in sequence.
CMD ["bash", "-c", "python scripts/train_autoencoder.py && python scripts/generate_precursor_data.py"]
