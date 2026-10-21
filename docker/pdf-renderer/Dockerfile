# pdf-renderer: HTML to PDF with chrome-headless-shell driven through puppeteer-core.
#
# Build (amd64 only; run under BuildKit so TARGETARCH is set):
#   docker build -t pdf-renderer --build-arg GIT_SHA="$(git rev-parse HEAD)" docker/pdf-renderer
# To use another Chrome for Testing build, pass both CHS_VERSION and CHS_SHA256 (see README.md).

# One literal FROM, so Dependabot sees the digest; the other stages start from it.
FROM node:24-trixie-slim@sha256:7f486cabe892bff8fef04c0f7da8dba84a560be3e4e2740b7a86afc57ebec315 AS base

# ---- chrome-headless-shell, downloaded and checked against a pinned SHA-256 -------------------------------
FROM base AS chs
ARG TARGETARCH
ARG CHS_VERSION=155.0.8059.84
ARG CHS_SHA256=a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c
RUN test "${TARGETARCH}" = "amd64" || { echo "pdf-renderer supports linux/amd64 only (TARGETARCH='${TARGETARCH}'); build with BuildKit on an amd64 host" >&2; exit 1; }
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 --connect-timeout 20 -o /tmp/chs.zip \
      "https://storage.googleapis.com/chrome-for-testing-public/${CHS_VERSION}/linux64/chrome-headless-shell-linux64.zip" \
    && echo "${CHS_SHA256}  /tmp/chs.zip" | sha256sum -c - \
    && unzip -q /tmp/chs.zip -d /tmp/chs \
    && mv /tmp/chs/chrome-headless-shell-linux64 /opt/chs \
    && chmod 0755 /opt/chs/chrome-headless-shell

# ---- production node_modules (no scripts run) ------------------------------------------------------------------
FROM base AS deps
ARG PUPPETEER_CORE_VERSION=25.14.0
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
    && test "$(node -p "require('./node_modules/puppeteer-core/package.json').version")" = "${PUPPETEER_CORE_VERSION}"

# ---- runtime -----------------------------------------------------------------------------------------------------------
FROM base AS runtime
ARG TARGETARCH
RUN test "${TARGETARCH}" = "amd64" || { echo "pdf-renderer supports linux/amd64 only (TARGETARCH='${TARGETARCH}')" >&2; exit 1; }

# Shared libraries chrome-headless-shell needs (the minimum `ldd` reports), tini, fontconfig and the font set
# of the Gotenberg 8.x image this service replaces. Packages are named without versions: Debian's security
# revisions are replaced and removed from the archive, so an exact pin would stop building within weeks. The
# font-file hash below is the guard against a font change slipping in, and the golden-PDF job (tests/golden-pdf)
# catches any change in the rendered pages.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tini \
      libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libdbus-1-3 libdrm2 libexpat1 libgbm1 \
      libglib2.0-0t64 libnspr4 libnss3 libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
      libxkbcommon0 libxrandr2 \
      fontconfig \
      fonts-liberation fonts-liberation2 \
      fonts-dejavu fonts-dejavu-core fonts-dejavu-extra fonts-dejavu-mono \
      fonts-noto-core fonts-noto-mono fonts-noto-cjk \
      fonts-noto-color-emoji \
      fonts-crosextra-carlito fonts-crosextra-caladea \
      fonts-opensymbol \
    && rm -rf /var/lib/apt/lists/*

# Debian's default fontconfig conf.d plus Gotenberg's rendering settings (identical in 8.25, 8.32, 8.37).
COPY fontconfig/100-gotenberg.conf /etc/fonts/conf.d/100-gotenberg.conf
# Last font step: build the cache now, because the root file system is read-only at run time.
RUN fc-cache -sf

# The font tree must equal the Gotenberg targets' (GCS live 8.32 and template 8.37 give the same value): the sorted
# list of font files fontconfig knows, hashed the way targets/probe.sh does. A Debian update that adds or drops a
# font file fails the build instead of silently changing the PDFs (the file list, not the package versions).
ARG FONT_FILELIST_SHA256=bb94b4513fc8a1aba5b2d7949632f3fc9311cad45ad288dc204555be0814986d
RUN actual="$(fc-list --format '%{file}\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1)" \
    && if [ "$actual" != "${FONT_FILELIST_SHA256}" ]; then \
         echo "font file list hash ${actual} differs from the pinned ${FONT_FILELIST_SHA256}" >&2; \
         fc-list --format '%{file}\n' | LC_ALL=C sort | uniq -c >&2; exit 1; \
       fi

COPY --from=chs /opt/chs /opt/chs
# Fail the build if the browser lacks a shared library.
RUN ! ldd /opt/chs/chrome-headless-shell | grep -q 'not found' \
    || { ldd /opt/chs/chrome-headless-shell | grep 'not found' >&2; exit 1; }

# No package manager at run time.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg \
      /opt/yarn-* \
    && groupadd --gid 10001 renderer \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin renderer

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

ENV NODE_ENV=production \
    HOME=/tmp/home \
    XDG_CONFIG_HOME=/tmp/xdg-config \
    XDG_CACHE_HOME=/tmp/xdg-cache \
    XDG_DATA_HOME=/tmp/xdg-data \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MALLOC_ARENA_MAX=2 \
    CHS_PATH=/opt/chs/chrome-headless-shell \
    PORT=3000

# Last, so a new commit (GIT_SHA) changes only these metadata lines and never invalidates the cached apt-get, font and
# node_modules layers above.
ARG CHS_VERSION=155.0.8059.84
ARG PUPPETEER_CORE_VERSION=25.14.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="pdf-renderer" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      pdf-renderer.chs-version="${CHS_VERSION}" \
      pdf-renderer.puppeteer-core-version="${PUPPETEER_CORE_VERSION}" \
      pdf-renderer.git-sha="${GIT_SHA}"

USER 10001:10001
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "src/server.mjs"]
