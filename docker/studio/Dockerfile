FROM supabase/studio:2026.09.21-sha-512201d@sha256:fdb56cfa1705ff6b4a21656b82b3fb1abbd411c05b5574d56a681ae223b7804b
# The upstream entrypoint runs Node directly; package-manager CLIs are build tools.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/pnpm \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/pnpm /usr/local/bin/pnpx
