FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /src
RUN curl -4 --connect-timeout 15 --max-time 120 --retry 2 -fsSL https://codeload.github.com/supabase/auth/tar.gz/refs/tags/v2.196.0 -o /tmp/source.tar.gz \
    && echo 'ce391568d026220b216c60f98f5549980e46aa97a156f477d317752b8c0debfb  /tmp/source.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY go.mod go.sum ./
COPY internal/forks/pgproto3 ./internal/forks/pgproto3
RUN --mount=type=cache,id=warehouse-security-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=warehouse-security-go-build,target=/root/.cache/go-build \
    go mod download && go mod verify \
    && (cd internal/forks/pgproto3 && go test ./...) \
    && go test -p=2 ./internal/crypto/... \
    && CGO_ENABLED=0 go build -p=2 -mod=readonly -trimpath -ldflags='-X github.com/supabase/auth/internal/utilities.Version=v2.196.0-warehouse.1' -o /out/auth .
FROM supabase/gotrue:v2.196.0@sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232
USER root
RUN apk upgrade --no-cache libcrypto3 libssl3
COPY --from=build /out/auth /usr/local/bin/auth
COPY --from=build /src/LICENSE /usr/share/doc/warehouse-auth/LICENSE
COPY --from=build /src/internal/forks/pgproto3/LICENSE /usr/share/doc/warehouse-auth/pgproto3-LICENSE
USER supabase
