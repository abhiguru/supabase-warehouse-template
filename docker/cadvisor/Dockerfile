FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/google/cadvisor/tar.gz/refs/tags/v0.60.6 -o /tmp/source.tar.gz \
    && echo 'de7a92116fcad156fd5792da486b164224c3989e2f71041612a20c54cef4e2f7  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY cmd/go.mod cmd/go.sum ./cmd/
WORKDIR /src/cmd
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && go test -p=2 ./... \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -o /out/cadvisor .
FROM ghcr.io/google/cadvisor:0.60.6@sha256:b8e7d1093144fd088f425ff003d75a4aa405de075db78dae3bc563730b1bd07a
COPY --from=build /out/cadvisor /usr/bin/cadvisor
COPY --from=build /src/LICENSE /usr/share/doc/warehouse-cadvisor/LICENSE
