FROM supabase/realtime:v2.143.3@sha256:768b559241dd234c4e8852c5c0f504e598b80f1df2ad4dd78d5486fbed2f17a2
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
