FROM python:3.12-alpine3.24@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir --upgrade pip==26.2.2 \
    && python -m pip install --no-cache-dir --only-binary=:all: -r requirements.txt \
    && addgroup -g 10001 dashboard \
    && adduser -D -H -u 10001 -G dashboard -s /sbin/nologin dashboard
COPY --chown=10001:10001 main.py sample_layout.py sample_upload.py ./
COPY --chown=10001:10001 static ./static
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-proxy-headers"]
