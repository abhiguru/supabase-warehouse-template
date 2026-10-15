FROM supabase/studio:2026.10.12-sha-3699278@sha256:948770ec467f00e6ae34c35018ef7cb23d7b30eb806b42c2cc0d7bcfdcf8a7a8
# Debian 12 base, running as root: apply the distribution's security updates,
# as the Realtime and Supavisor recipes do. The remaining simple-git and Next.js
# findings are in the application and need a later publisher tag
# (CONTAINER_SECURITY.md, "Open items").
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
# The upstream entrypoint runs Node directly; package-manager CLIs are build tools.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/pnpm \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/pnpm /usr/local/bin/pnpx \
    /usr/local/bin/pn /usr/local/bin/pnx
