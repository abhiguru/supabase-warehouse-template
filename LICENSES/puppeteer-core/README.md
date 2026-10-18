# puppeteer-core

`docker/pdf-renderer/package.json` pins puppeteer-core exactly; `package-lock.json` pins it and its dependencies by
integrity hash, and `npm ci --omit=dev --ignore-scripts` installs them when the image is built. No package source is
committed here.

- Project: https://github.com/puppeteer/puppeteer (Copyright 2017 Google Inc.)
- Licence: Apache-2.0, full text in `LICENSES/Apache-2.0.txt`.
- Dependencies keep their own upstream terms, recorded in `package-lock.json` and in each package's `LICENSE`
  inside the image's `node_modules`.
