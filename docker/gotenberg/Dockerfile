FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/pdfcpu/pdfcpu/tar.gz/refs/tags/v0.15.0 -o /tmp/source.tar.gz \
    && echo '69924a7363ea19b4f3d4799ebf78bcabfec75a735c9569983a6e2834b5e8c6b3  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && go test -p=2 ./pkg/pdfcpu/model \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X main.version=v0.15.0-warehouse.1 -X github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model.VersionStr=v0.15.0 -X main.builtBy=warehouse' -o /out/pdfcpu ./cmd/pdfcpu
FROM gotenberg/gotenberg:8.37.0@sha256:f29984bd1e226bf1b93ba90af06000afa8b315853e99d27b9aaa41b93f15c769
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/pdfcpu /usr/bin/pdfcpu
COPY --from=build /src/LICENSE.txt /usr/share/doc/warehouse-pdfcpu/LICENSE.txt
USER gotenberg
