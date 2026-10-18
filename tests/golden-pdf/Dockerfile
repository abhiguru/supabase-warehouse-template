# Rasteriser for the golden-PDF job (tests/golden-pdf/run.sh): a pinned poppler, so the
# pixels of a golden do not move with the CI runner's own packages. Base by digest;
# poppler-utils pinned to the trixie version the goldens were made with. If Debian drops
# that version, bump it here and regenerate the goldens in the same change
# (bash tests/golden-pdf/run.sh --update) and review the montage of what moved.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
RUN apt-get update \
    && apt-get install -y --no-install-recommends poppler-utils=25.03.0-5+deb13u4 \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["pdftoppm"]
