# Stage 1 only supplies the edge-runtime binary. The upstream image also holds a
# 277 MB debug-symbols file and an unused 50 MB ONNX runtime (AI inference); the
# binary does not link either (ldd shows only libgcc_s, libm and libc).
# Both FROM lines must move together: the final stage's Debian release must match
# the upstream image's, because the binary needs that release's glibc.
FROM supabase/edge-runtime:v1.77.4@sha256:ad45164b7548bf5820ed7be714789c17ac2865edce79a09cfb4c3756c3d365a8 AS upstream

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
ENTRYPOINT ["edge-runtime"]
