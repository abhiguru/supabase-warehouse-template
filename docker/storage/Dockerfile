FROM supabase/storage-api:v1.80.2@sha256:95b217a9c59e0ac06c6dcb539df3189a1668a2445fb43dbf29660d6968ffd7d2
WORKDIR /app
# Preserve the precompiled application and existing native modules. Patch only
# locked dependency versions; never run package lifecycle scripts in the image.
COPY package.json package-lock.json ./
# Alpine base: take the distribution's security updates first.
RUN apk upgrade --no-cache
# npm install is kept (the base image's tree is patched in place), but the lockfile is
# the contract: the build fails if npm rewrote package-lock.json, so a version nobody
# reviewed cannot slip in. The production tree is checked with npm ls;
# an invalid, missing or extraneous package fails the build (problems go to stderr).
RUN before="$(sha256sum package-lock.json | cut -d' ' -f1)" \
    && npm install --omit=dev --ignore-scripts --no-audit --no-fund \
    && after="$(sha256sum package-lock.json | cut -d' ' -f1)" \
    && if [ "$before" != "$after" ]; then echo "package-lock.json changed during npm install ($before -> $after); regenerate it with: npx -y npm@11.12.1 install --package-lock-only --ignore-scripts (docker/storage/README.md)" >&2; exit 1; fi \
    && npm ls --omit=dev --all > /dev/null \
    && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
