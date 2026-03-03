FROM python:3.11-slim

WORKDIR /workspace

# Copy requirements first so the pip install layer is cached
# independently of script changes.
COPY docker/ml/requirements.txt ./requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

# Copy training scripts and pre-existing model assets.
COPY scripts/ ./scripts/
COPY assets/ml/ ./assets/ml/

# Default command: run both training scripts in sequence.
CMD ["bash", "-c", "python scripts/train_autoencoder.py && python scripts/generate_precursor_data.py"]
