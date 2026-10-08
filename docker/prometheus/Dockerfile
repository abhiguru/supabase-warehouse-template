FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/prometheus/prometheus/tar.gz/refs/tags/v3.14.0 -o /tmp/source.tar.gz \
    && echo '9294e72722fe8f90e54994ce36f331ea6176cb0edc4149cbf1d023bc89536505  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1 \
    && curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://github.com/prometheus/prometheus/releases/download/v3.14.0/prometheus-web-ui-3.14.0.tar.gz -o /tmp/ui.tar.gz \
    && echo 'be18623c5891d32572998070de0d48522c966b737d9204aa41e0e88d6318e029  /tmp/ui.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/ui.tar.gz -C web/ui
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && bash scripts/compress_assets.sh \
    && go test -p=2 ./config \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -tags=builtinassets -trimpath -ldflags='-X github.com/prometheus/common/version.Version=3.14.0-warehouse.1' -o /out/prometheus ./cmd/prometheus \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -tags=builtinassets -trimpath -ldflags='-X github.com/prometheus/common/version.Version=3.14.0-warehouse.1' -o /out/promtool ./cmd/promtool
FROM prom/prometheus:v3.14.0@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0
COPY --from=build /out/prometheus /bin/prometheus
COPY --from=build /out/promtool /bin/promtool
COPY --from=build /src/LICENSE /src/NOTICE /usr/share/doc/warehouse-prometheus/
