FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS gosu
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
FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS walg
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/wal-g/wal-g/tar.gz/refs/tags/v3.0.9 -o /tmp/source.tar.gz \
    && echo 'b06bc26c4865c07d0c269101910f63c7eedd03790b7c054a7da0980a7a9cc31d  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY walg.go.mod ./go.mod
COPY walg.go.sum ./go.sum
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && go test -mod=readonly -p=2 ./utility/... \
    && CGO_ENABLED=0 go build -mod=readonly -p=2 -trimpath -ldflags='-X github.com/wal-g/wal-g/cmd/pg.walgVersion=v3.0.9-warehouse.1' -o /out/wal-g ./main/pg
FROM supabase/postgres:15.8.1.060@sha256:0e2279598bc0224fb5960c3a61eb23270cd60119427f3a7bdec86ba282600dcc
RUN apt-get update && apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev && rm -rf /var/lib/apt/lists/*
COPY --from=gosu /out/gosu /usr/local/bin/gosu
COPY --from=walg /out/wal-g /usr/local/bin/wal-g
COPY --from=gosu /src/LICENSE /usr/share/doc/warehouse-gosu/LICENSE
COPY --from=walg /src/LICENSE.md /usr/share/doc/warehouse-walg/LICENSE.md
RUN gosu nobody id && wal-g --version
