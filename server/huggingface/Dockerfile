FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 DENO_INSTALL=/usr/local PORT=7860 WORK_DIR=/tmp
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl unzip \
 && curl -fsSL https://deno.land/install.sh | sh -s -- -y \
 && apt-get purge -y unzip && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install -U -r requirements.txt && chmod -R a+w /usr/local/lib/python3.12/site-packages /usr/local/bin
COPY app.py .
EXPOSE 7860
# Start the web server at once (fast wake-up on the free plan). The newest yt-dlp is installed
# when the image is built (every deploy). Access log OFF: no links are logged.
CMD exec uvicorn app:app --host 0.0.0.0 --port 7860 --no-access-log --proxy-headers --forwarded-allow-ips='*'
