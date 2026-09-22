FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/prometheus/alertmanager/tar.gz/refs/tags/v0.34.1 -o /tmp/source.tar.gz \
    && echo '2f6bce4f4b2b28aec4e58fad1341f47cde9c30adb556399472a8831942057941  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1 \
    && curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://github.com/prometheus/alertmanager/releases/download/v0.34.1/alertmanager-web-ui-0.34.1.tar.gz -o /tmp/ui.tar.gz \
    && echo '881fe0f7beb9573f35be47dd233af6220e72c8db72c03bcd1780402eb8dc1307  /tmp/ui.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/ui.tar.gz -C ui/app
# Upstream v0.34.1 module lock with gRPC updated to v1.83.2.
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && go test -p=2 ./config ./api/... \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X github.com/prometheus/common/version.Version=0.34.1-warehouse.1' -o /out/alertmanager ./cmd/alertmanager \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X github.com/prometheus/common/version.Version=0.34.1-warehouse.1' -o /out/amtool ./cmd/amtool
FROM prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a
COPY --from=build /out/alertmanager /bin/alertmanager
COPY --from=build /out/amtool /bin/amtool
COPY --from=build /src/LICENSE /src/NOTICE /usr/share/doc/warehouse-alertmanager/
