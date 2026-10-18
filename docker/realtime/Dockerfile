FROM supabase/realtime:v2.143.4@sha256:35e99d3f1cbba5aa5585e8ac3cf70ecc54909ee4aee0626effed93c60fb41439
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
