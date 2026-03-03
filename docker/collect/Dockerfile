FROM python:3.11-slim

WORKDIR /workspace

COPY docker/collect/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY docker/collect/app.py ./app.py

EXPOSE 8765

CMD ["python", "app.py"]
