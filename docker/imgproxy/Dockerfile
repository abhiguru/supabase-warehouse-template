FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS compiler
FROM ghcr.io/imgproxy/imgproxy-base:v3.15.9@sha256:c5b6669b6167d69c8db4377ef24bc5c267f48c48d3b94c5253b99202b9052b5b AS build
RUN rm -rf /usr/local/go
COPY --from=compiler /usr/local/go /usr/local/go
WORKDIR /app
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/imgproxy/imgproxy/tar.gz/refs/tags/v3.31.4 -o /tmp/source.tar.gz \
    && echo '8a69927ec5c4dcc57de700613dafb73616f3807cb49f78eaac1f99ab880c39bd  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY go.mod go.sum ./
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    bash -c 'go mod download && go mod verify && CGO_ENABLED=1 go build -p=2 -mod=readonly -trimpath -o /out/imgproxy .'
FROM darthsim/imgproxy:v4.0.17@sha256:db0b4b9cd690c8b3590203dea300fb759a18c4ec2af7b37424f0bdef23ce317d
USER root
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/imgproxy /opt/imgproxy/bin/imgproxy
COPY --from=build /app/LICENSE /usr/share/doc/warehouse-imgproxy/LICENSE
USER 999
