FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/prometheus/prometheus/tar.gz/refs/tags/v3.15.0 -o /tmp/source.tar.gz \
    && echo 'd6383dea2f9b26c1673a52859c453653f2c6c046f7fb6d01db59603a65a732eb  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1 \
    && curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-web-ui-3.15.0.tar.gz -o /tmp/ui.tar.gz \
    && echo 'fa8c918ed05e3f89e232e9b69eccd6ed074602cd9e8a2cab7a92bec9651974ae  /tmp/ui.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/ui.tar.gz -C web/ui
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && bash scripts/compress_assets.sh \
    && go test -p=2 ./config \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -tags=builtinassets -trimpath -ldflags='-X github.com/prometheus/common/version.Version=3.15.0-warehouse.1' -o /out/prometheus ./cmd/prometheus \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -tags=builtinassets -trimpath -ldflags='-X github.com/prometheus/common/version.Version=3.15.0-warehouse.1' -o /out/promtool ./cmd/promtool
FROM prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e
COPY --from=build /out/prometheus /bin/prometheus
COPY --from=build /out/promtool /bin/promtool
COPY --from=build /src/LICENSE /src/NOTICE /usr/share/doc/warehouse-prometheus/
