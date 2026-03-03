# Build context must be the repo root.
# Correct: docker build -f docker/watcher/Dockerfile .
FROM python:3.11-slim
WORKDIR /workspace
COPY docker/watcher/watch.py ./watch.py
CMD ["python", "watch.py"]
