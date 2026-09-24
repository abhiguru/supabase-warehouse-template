# Keep the publisher's application and all bundled plugin IDs. Replace seven
# bundled plugins with complete, publisher-signed, checksum-pinned releases.
FROM grafana/grafana:13.2.2@sha256:ac461fb352abc50da10a51c7d02462e9c05488f11f53f14b3ad79a8145f638a0

ARG TARGETARCH
USER root
COPY grafana/plugins.lock grafana/install-plugins.sh /tmp/
RUN apk add --no-cache --upgrade 'libcrypto3>=3.5.8-r0' 'libssl3>=3.5.8-r0' \
    && TARGETARCH="$TARGETARCH" sh /tmp/install-plugins.sh \
    && rm /tmp/plugins.lock /tmp/install-plugins.sh
ENV GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false
USER 472
