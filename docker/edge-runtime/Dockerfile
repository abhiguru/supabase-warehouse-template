# Stage 1 only supplies the edge-runtime binary. The upstream image also holds a
# 277 MB debug-symbols file and an unused 50 MB ONNX runtime (AI inference); the
# binary does not link either (ldd shows only libgcc_s, libm and libc).
# Both FROM lines must move together: the final stage's Debian release must match
# the upstream image's, because the binary needs that release's glibc.
FROM supabase/edge-runtime:v1.78.1@sha256:362e9177660ae4d3affb6978480cc6161a8ea0764f1c2c7f738348eda1c3fbf2 AS upstream

# Same Debian release (bookworm) as the upstream image, so the binary's libc matches.
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
# Debian security updates for the whole image (perl-base among them), not
# only PCRE2; the PCRE2 version check stays (docs/CONTAINER_SECURITY.md).
# ca-certificates: outbound HTTPS (SMS provider, central JWKS); tzdata: time zones.
# bash and grep (already in the base) are what the compose healthcheck uses.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates tzdata \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libpcre2-8-0)" ge '10.42-1+deb12u1' \
    && rm -rf /var/lib/apt/lists/*
COPY --from=upstream /usr/local/bin/edge-runtime /usr/local/bin/edge-runtime
# The binary is only copied, so a base that no longer matches it would build and then fail when `functions` starts, with
# every edge function down: sign-in codes, the central exchange and the PDFs (upstream moving to Debian 13 while this stage
# stays on bookworm gives a glibc error). Run it once here, as docker/pdf-renderer's Dockerfile runs `ldd` on
# chrome-headless-shell: if it does not link and start on this base, the build fails.
RUN ["edge-runtime", "--version"]
# Fill the runtime's module cache (/root/.cache/deno) with what a `node:` import needs. The runtime fetches the @types/node typings
# from registry.npmjs.org the first time a worker with a `node:` import is built, so a functions container created while the
# facility's internet is down could not start those workers (sign-in codes, the central exchange, printing). Starts the runtime
# once over a tiny worker (docker/edge-runtime/warmup, deleted again after) and keeps the cache in the image. Needs the internet
# at build time only; the build fails if the worker does not answer.
COPY warmup /opt/warmup
RUN bash /opt/warmup/run.sh && rm -rf /opt/warmup /tmp/warmup.log
ENTRYPOINT ["edge-runtime"]
