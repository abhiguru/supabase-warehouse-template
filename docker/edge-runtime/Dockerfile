# Stage 1 only supplies the edge-runtime binary. The upstream image also holds a
# 277 MB debug-symbols file and an unused 50 MB ONNX runtime (AI inference); the
# binary does not link either (ldd shows only libgcc_s, libm and libc).
# Both FROM lines must move together: the final stage's Debian release must match
# the upstream image's, because the binary needs that release's glibc.
FROM supabase/edge-runtime:v1.77.8@sha256:178c041398a33ded8219344382d0672a90051d1babbf0af03425cafe20039a75 AS upstream

# Same Debian release (bookworm) as the upstream image, so the binary's libc matches.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
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
ENTRYPOINT ["edge-runtime"]
