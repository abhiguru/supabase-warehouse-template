# Tapo sensor bridge (README.md). GPL-3.0-or-later, see LICENSE in this folder.
# python:3.14-slim-bookworm (Python 3.14.x), multi-architecture index digest, resolved 2026-10-13.
FROM python:3.14-slim-bookworm@sha256:48b13b003dda20b16f9442b8475aa05fe21bf6579a8c881db92ffb4d8fd20f83

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Wheels only: nothing is compiled, so the image needs no compiler.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --only-binary=:all: --requirement /app/requirements.txt \
    && groupadd --system --gid 10001 bridge \
    && useradd --system --uid 10001 --gid 10001 --home-dir /nonexistent --no-create-home \
       --shell /usr/sbin/nologin bridge \
    && mkdir -p /data \
    && chown 10001:10001 /data \
    && chmod 0700 /data

COPY docker-entrypoint.sh /usr/local/bin/sensor-bridge-entrypoint
COPY LICENSE README.md /app/
COPY sensor_bridge /app/sensor_bridge
COPY tests /app/tests
RUN chmod 0755 /usr/local/bin/sensor-bridge-entrypoint \
    && chmod -R a+rX,go-w /app

WORKDIR /app
USER 10001:10001
VOLUME /data

# The loop rewrites the health file every second; older than 120 s means it is stuck.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["python", "-m", "sensor_bridge.health"]

ENTRYPOINT ["sensor-bridge-entrypoint"]
CMD []
