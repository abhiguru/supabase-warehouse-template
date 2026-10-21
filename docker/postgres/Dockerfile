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
# The official PostgreSQL 18 image (Debian trixie, pinned by tag and index digest). The recipe exists
# only for gosu: the image ships gosu 1.19 built with an old Go toolchain, and Trivy reports fixable Go
# standard-library CVEs in that binary. Rebuilding gosu with the pinned Go builder above clears them.
FROM postgres:18.6-trixie@sha256:1267c7e692de235fda2a50dbcdbcbca4672ea6a0298576a6bd9d07cafc319b32
COPY --from=gosu /out/gosu /usr/local/bin/gosu
COPY --from=gosu /src/LICENSE /usr/share/doc/warehouse-gosu/LICENSE
RUN gosu nobody id \
    && postgres --version | grep -q 'PostgreSQL) 18\.'
# Collation guard. Text indexes depend on glibc's collation of en_US.UTF-8; a base image whose libc6 or locales
# package differs (a Dependabot digest bump) can reorder strings and corrupt every text index until a REINDEX. The
# versions below are the ones the data of the facilities was built with. A bump that changes them fails this build:
# check the glibc changelog for collation changes, plan a REINDEX if there are any, then update the line below.
RUN set -eu; \
    expected='libc-bin 2.41-12+deb13u4 libc6 2.41-12+deb13u4 locales 2.41-12+deb13u4'; \
    actual="$(dpkg-query -W -f='${Package} ${Version}\n' libc6 libc-bin locales | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"; \
    [ "$actual" = "$expected" ] || { echo "Refused: the base image's glibc or locales differ from the recorded versions (docker/postgres/Dockerfile). Expected '$expected', found '$actual'. Collations may have changed: see the comment above this line." >&2; exit 1; }
