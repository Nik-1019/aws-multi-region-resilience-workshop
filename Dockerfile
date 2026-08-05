# ---------------------------------------------------------------------------
# Stage 1: build wheels so the final image needs no compiler toolchain.
# ---------------------------------------------------------------------------
FROM python:3.11-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime.
# ---------------------------------------------------------------------------
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_PORT=80

RUN useradd --create-home --shell /usr/sbin/nologin workshop

WORKDIR /app

COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY app.py .
COPY templates/ ./templates/

USER workshop
EXPOSE 80

HEALTHCHECK --interval=15s --timeout=4s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,os,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('APP_PORT','80')+'/health', timeout=3).status==200 else 1)"

# One worker, many threads -- deliberately. Failover state lives in process
# memory, so a second worker would make the "Last Failover" card flicker
# depending on which process answered. Threads share that memory; 8 of them is
# ample for a demo app whose only real work is one database round trip.
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${APP_PORT:-80} --workers 1 --threads 8 --timeout 30 --access-logfile - app:app"]
