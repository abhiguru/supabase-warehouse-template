FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS gosu
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/tianon/gosu/tar.gz/refs/tags/1.19 -o /tmp/source.tar.gz \
    && echo 'cd9719b775dbfedae53923c9b0dc792b66d42c51e0b36652ed6f747fbadc0164  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY gosu.go.mod ./go.mod
COPY gosu.go.sum ./go.sum
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X main.Version=1.19-warehouse.1' -o /out/gosu .
FROM supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6
# Upgrade only the Ubuntu packages with a fixed HIGH/CRITICAL advisory
# (scripts/scan-images.sh). Not a full upgrade: the Nix-built PostgreSQL reads
# Ubuntu's locale archive (LOCALE_ARCHIVE), so glibc and the locale data stay
# as the pinned base has them, and the build fails if either changes. A fixed
# glibc or locales advisory goes into docker/image-exceptions.json as an
# advisory entry, never into this list: a collation change needs a reindex.
RUN before="$(dpkg-query -W -f='${Package} ${Version}\n' libc6 libc-bin locales; sha256sum /usr/lib/locale/locale-archive)" \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --only-upgrade \
       linux-libc-dev openssl libssl3t64 sudo \
       dirmngr gnupg gnupg-l10n gnupg-utils gpg gpg-agent gpg-wks-client gpgconf gpgsm gpgv keyboxd \
       packagekit packagekit-tools libpackagekit-glib2-18 gir1.2-packagekitglib-1.0 \
    && after="$(dpkg-query -W -f='${Package} ${Version}\n' libc6 libc-bin locales; sha256sum /usr/lib/locale/locale-archive)" \
    && { [ "$before" = "$after" ] || { echo 'Refused: this upgrade changed glibc, locales or /usr/lib/locale/locale-archive, which the database collations depend on (docker/postgres/Dockerfile).' >&2; exit 1; }; } \
    && rm -rf /var/lib/apt/lists/*
COPY --from=gosu /out/gosu /usr/local/bin/gosu
COPY --from=gosu /src/LICENSE /usr/share/doc/warehouse-gosu/LICENSE
# wal-g (continuous archiving) is not used: backups are pg_dump and archive_mode
# is off. The base image's binary has known CVEs, so it is removed, not rebuilt,
# with its helper /home/postgres/wal_fetch.sh (mode 644, nothing calls it; it runs
# "sudo -u wal-g wal-g wal-fetch"). The settings file /etc/postgresql-custom/wal-g.conf
# stays (all commented out except hot_standby = off): the image's own
# postgresql.conf includes it.
RUN rm -f /usr/local/bin/wal-g /home/postgres/wal_fetch.sh \
    && gosu nobody id \
    && ! command -v wal-g
