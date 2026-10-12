FROM supabase/storage-api:v1.79.38@sha256:7903ad62951b6b7978fabed4c5db26d10da7c4fea10ee9b4fdfff86440f8b206
WORKDIR /app
# Preserve the precompiled application and existing native modules. Patch only
# locked dependency versions; never run package lifecycle scripts in the image.
COPY package.json package-lock.json ./
RUN npm install --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm ls --omit=dev \
    && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
