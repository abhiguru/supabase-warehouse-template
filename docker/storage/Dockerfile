# Stage 1: the publisher's image with its precompiled application and native modules (built with g++, make and
# python3, which this stage keeps and the final image does not). Patch only locked dependency versions; never run
# package lifecycle scripts.
FROM supabase/storage-api:v1.80.2@sha256:95b217a9c59e0ac06c6dcb539df3189a1668a2445fb43dbf29660d6968ffd7d2 AS patched
WORKDIR /app
COPY package.json package-lock.json ./
# npm install is kept (the base image's tree is patched in place), but the lockfile is
# the contract: the build fails if npm rewrote package-lock.json, so a version nobody
# reviewed cannot slip in. The production tree is checked with npm ls;
# an invalid, missing or extraneous package fails the build (problems go to stderr).
RUN before="$(sha256sum package-lock.json | cut -d' ' -f1)" \
    && npm install --omit=dev --ignore-scripts --no-audit --no-fund \
    && after="$(sha256sum package-lock.json | cut -d' ' -f1)" \
    && if [ "$before" != "$after" ]; then echo "package-lock.json changed during npm install ($before -> $after); regenerate it with: npx -y npm@11.12.1 install --package-lock-only --ignore-scripts (docker/storage/README.md)" >&2; exit 1; fi \
    && npm ls --omit=dev --all > /dev/null

# Stage 2 (the image that runs): a clean Node image of the same major and Alpine as the publisher's (24.21.0,
# 3.23), without the compilers and Python of stage 1, with only the patched /app copied over. Keep the Node
# version in step with stage 1's (docker/storage/README.md).
FROM node:24.21.0-alpine3.23@sha256:9ec4a2e289874ed0d722e1772ec2de45d2801541db8612f3638b26f128c69ac2
# Alpine base: take the distribution's security updates first. No package manager at run time.
RUN apk upgrade --no-cache \
    && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*
WORKDIR /app
COPY --from=patched /app /app
# The publisher sets VERSION (the Storage version it reports); keep it equal to stage 1's tag.
ENV VERSION=1.80.2
EXPOSE 5000
# The base image's ENTRYPOINT (docker-entrypoint.sh) is kept, as in the publisher's image.
CMD ["node", "dist/start/server.js"]
