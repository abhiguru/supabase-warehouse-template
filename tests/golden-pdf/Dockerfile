# Rasteriser and pixel comparer for the golden-PDF job (tests/golden-pdf/run.sh): pdftoppm (poppler-utils) and
# ImageMagick's `compare`, installed from a FIXED snapshot of the Debian archive, so the pixels of a golden do not
# move with the CI runner or with a later security update of poppler, freetype, libpng or zlib.
#
# This is a TEST container. The no-snapshot-mirror rule for production images (owner decision D5: build from the live
# mirrors and rescan before every release) deliberately does not apply here: nothing from this image ships, and its
# whole purpose is a byte-stable rasteriser. To move to a newer poppler, change the timestamp, run
# `bash tests/golden-pdf/run.sh` (compare) and review any page that moved, then regenerate with --update.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG SNAPSHOT=20261018T000000Z
RUN rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list \
    && echo "deb http://snapshot.debian.org/archive/debian/${SNAPSHOT}/ trixie main" > /etc/apt/sources.list \
    && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends poppler-utils imagemagick ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pdftoppm -v 2>&1 | head -1 && compare -version | head -1
COPY compare-case.sh /usr/local/bin/compare-case
ENTRYPOINT ["/bin/sh"]
