FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 DENO_INSTALL=/usr/local
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl unzip \
 && curl -fsSL https://deno.land/install.sh | sh -s -- -y \
 && apt-get purge -y unzip && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
EXPOSE 8000
# yt-dlp is refreshed on every start (sites change often). Access log OFF: no links are logged.
CMD pip install -q -U "yt-dlp[default]" || true; \
    exec uvicorn app:app --host 0.0.0.0 --port ${PORT:-8000} --no-access-log --proxy-headers --forwarded-allow-ips='*'
