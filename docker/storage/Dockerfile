FROM supabase/storage-api:v1.80.2@sha256:95b217a9c59e0ac06c6dcb539df3189a1668a2445fb43dbf29660d6968ffd7d2
WORKDIR /app
# Preserve the precompiled application and existing native modules. Patch only
# locked dependency versions; never run package lifecycle scripts in the image.
COPY package.json package-lock.json ./
RUN npm install --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm ls --omit=dev \
    && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
