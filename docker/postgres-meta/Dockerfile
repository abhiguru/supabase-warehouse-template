FROM supabase/postgres-meta:v0.99.0@sha256:9a079ac1c94d89629262822a4bd1902d5b1be4adb464e5a0a8fd078aaed72158 AS build
USER root
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl patch && rm -rf /var/lib/apt/lists/* \
    && curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/supabase/postgres-meta/tar.gz/refs/tags/v0.99.0 -o /tmp/source.tar.gz \
    && echo '8d3974ac52eaa4ddd7d0462ac1bd30f9e0e50b511fa96a537d6f3f9cc28e726e  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY package.json package-lock.json fastify5.patch vitest4.patch ./
RUN patch -p1 < fastify5.patch \
    && patch -p1 < vitest4.patch \
    && npm ci --ignore-scripts --no-audit --no-fund \
    && npm run check && npm run build \
    && npm exec -- vitest run test/app.test.ts test/admin-app.test.ts test/utils.test.ts --maxWorkers=1 --no-file-parallelism \
    && npm prune --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm ls --omit=dev
FROM supabase/postgres-meta:v0.99.0@sha256:9a079ac1c94d89629262822a4bd1902d5b1be4adb464e5a0a8fd078aaed72158
USER root
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/* \
    /usr/src/app/node_modules /usr/src/app/dist /usr/local/lib/node_modules/npm \
    /usr/local/lib/node_modules/pnpm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/pnpm /usr/local/bin/pnpx
COPY --from=build /src/package.json /src/package-lock.json /usr/src/app/
COPY --from=build /src/dist /usr/src/app/dist
COPY --from=build /src/node_modules /usr/src/app/node_modules
COPY --from=build /src/LICENSE /usr/share/doc/warehouse-postgres-meta/LICENSE
