FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/prometheus-community/postgres_exporter/tar.gz/refs/tags/v0.20.1 -o /tmp/source.tar.gz \
    && echo 'be5d9b71cdedcc5bd484869a2a1c66e51f76d5620ebf681781f22acc0cba283b  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && go test -p=2 ./collector ./config ./exporter \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X github.com/prometheus/common/version.Version=0.20.1-warehouse.1' -o /out/postgres_exporter ./cmd/postgres_exporter
FROM prometheuscommunity/postgres-exporter:v0.20.1@sha256:ac5ec343104fae0e2d84a27bb8d69b38430a11910c5382cad85d478d2bab713e
COPY --from=build /out/postgres_exporter /bin/postgres_exporter
COPY --from=build /src/LICENSE /src/NOTICE /usr/share/doc/warehouse-postgres-exporter/
