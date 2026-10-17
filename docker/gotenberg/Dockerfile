FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS build
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
# The publisher's /usr/bin/gotenberg is built with Go 1.27.1 and
# golang.org/x/net 0.58.0, both behind fixed HIGH advisories (8.38.1, the newest
# tag on 2026-10-17, still has Go 1.27.1 and x/net 0.59.0). Rebuild the same
# 8.37.0 source with the pinned Go 1.27.2 and the golang.org/x/* updates in
# gotenberg.go.mod (the only changes from upstream's go.mod), as pdfcpu above.
# Upstream's own test suite is not run here: every operator install builds this
# image, and its tests include timing-sensitive ones (TestProcessSupervisor_
# ReqQueueSize failed on a loaded CI runner on 2026-10-17), so an upstream flake
# would fail a real install. The verified module graph and the readonly build
# of the tagged source are the checks; the document tests exercise the binary.
FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS gotenberg
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/gotenberg/gotenberg/tar.gz/refs/tags/v8.37.0 -o /tmp/source.tar.gz \
    && echo 'b6395f7c819cd7c7a6ad9e2c1de9723639f8b150f160f777325ce16449ad4658  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY gotenberg.go.mod ./go.mod
COPY gotenberg.go.sum ./go.sum
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags="-X 'github.com/gotenberg/gotenberg/v8/cmd.Version=8.37.0'" -o /out/gotenberg ./cmd/gotenberg
FROM gotenberg/gotenberg:8.37.0@sha256:f29984bd1e226bf1b93ba90af06000afa8b315853e99d27b9aaa41b93f15c769
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/pdfcpu /usr/bin/pdfcpu
COPY --from=build /src/LICENSE.txt /usr/share/doc/warehouse-pdfcpu/LICENSE.txt
COPY --from=gotenberg /out/gotenberg /usr/bin/gotenberg
COPY --from=gotenberg /src/LICENSE /usr/share/doc/warehouse-gotenberg/LICENSE
USER gotenberg
