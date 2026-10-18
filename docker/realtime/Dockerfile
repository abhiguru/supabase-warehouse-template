FROM supabase/realtime:v2.144.0@sha256:d97bf891884ef035a5068f01e2ea1ce0e9649c21c19ab14a91d70fcfea3b03d4
# The publisher's image runs as nobody since v2.14x; the package upgrade needs
# root, and the service goes back to the publisher's user afterwards.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER nobody
