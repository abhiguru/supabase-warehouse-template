FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/prometheus/node_exporter/tar.gz/refs/tags/v1.12.1 -o /tmp/source.tar.gz \
    && echo 'a90f1df0fde58d216d4a7d342e64831d2e3257db8084deadbe69754d34b15142  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && ./ttar -C collector/fixtures -x -f collector/fixtures/sys.ttar \
    && ./ttar -C collector/fixtures -x -f collector/fixtures/udev.ttar \
    && go test -p=2 ./collector \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X github.com/prometheus/common/version.Version=1.12.1-warehouse.1' -o /out/node_exporter .
FROM prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0
COPY --from=build /out/node_exporter /bin/node_exporter
COPY --from=build /src/LICENSE /src/NOTICE /usr/share/doc/warehouse-node-exporter/
