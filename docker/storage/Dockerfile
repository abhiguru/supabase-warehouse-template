FROM supabase/storage-api:v1.79.14@sha256:b2525671e665c3bf15bfaba4b0cc1754f0cb8f36cdb9d6dce13beed58b854ae1
WORKDIR /app
# Preserve the precompiled application and existing native modules. Patch only
# locked dependency versions; never run package lifecycle scripts in the image.
COPY package.json package-lock.json ./
RUN npm install --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm ls --omit=dev \
    && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
