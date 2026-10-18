# chrome-headless-shell (Chrome for Testing)

The PDF renderer image (`docker/pdf-renderer/Dockerfile`) downloads the `chrome-headless-shell-linux64.zip` archive
of one Chrome for Testing release at build time (`ARG CHS_VERSION`, checked against `ARG CHS_SHA256`). Nothing from
it is committed or redistributed in this repository.

- Project: Chromium, https://www.chromium.org/ ; build channel: https://googlechromelabs.github.io/chrome-for-testing/
- Licence: BSD-3-Clause (the Chromium Project licence, `LICENSE` here). The archive also bundles third-party code
  under its own terms (FFmpeg, ICU, Skia, V8, HarfBuzz and others); the complete list ships inside the archive as
  `LICENSE.headless_shell` and stays in the image at `/opt/chs/LICENSE.headless_shell` (the recipe copies the whole archive directory) so that anyone who
  receives a built image receives the notices with it.
- An operator who distributes a built image distributes Chromium and must keep those notices with it.
