FROM supabase/studio:2026.10.05-sha-94b8b06@sha256:d878dcd9dba73b66d1c2c19aeaf53d07704e71604d93013225be1d1c51475237
# Debian 12 base, running as root: apply the distribution's security updates,
# as the Realtime and Supavisor recipes do. The Next.js and simple-git findings
# are in the application and need a newer publisher tag (CONTAINER_SECURITY.md).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
# The upstream entrypoint runs Node directly; package-manager CLIs are build tools.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/pnpm \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/pnpm /usr/local/bin/pnpx
