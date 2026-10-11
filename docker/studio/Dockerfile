FROM supabase/studio:2026.09.21-sha-512201d@sha256:fdb56cfa1705ff6b4a21656b82b3fb1abbd411c05b5574d56a681ae223b7804b
# Debian 12 base, running as root: apply the distribution's security updates,
# as the Realtime and Supavisor recipes do. The Next.js and simple-git findings
# are in the application and need a newer publisher tag (CONTAINER_SECURITY.md).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
# The upstream entrypoint runs Node directly; package-manager CLIs are build tools.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/pnpm \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/pnpm /usr/local/bin/pnpx
