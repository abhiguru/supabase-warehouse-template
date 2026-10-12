FROM supabase/realtime:v2.143.2@sha256:b816746b7039071e2d1161413bed6444a3252a59a1bf79141b677b70a8d54bec
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
