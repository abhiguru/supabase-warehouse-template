FROM supabase/realtime:v2.143.1@sha256:339a3f9e1854f1ece7f973ee97225c3b5762a4e07ff100ca8458f96a4993c86a
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
