FROM supabase/realtime:v2.143.0@sha256:29d1ae059e377e12d51ec90d30f84b8a312692018b95d24944456a52e9f72e82
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
