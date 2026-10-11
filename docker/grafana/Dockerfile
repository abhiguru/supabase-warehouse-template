# Remove unused bundled plugins and replace the four retained plugins with
# complete, publisher-signed, checksum-pinned releases.
FROM grafana/grafana:13.2.3@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572

ARG TARGETARCH
USER root
COPY grafana/plugins.lock grafana/install-plugins.sh /tmp/
RUN apk add --no-cache --upgrade 'libcrypto3>=3.5.8-r0' 'libssl3>=3.5.8-r0' \
    && TARGETARCH="$TARGETARCH" sh /tmp/install-plugins.sh \
    && rm /tmp/plugins.lock /tmp/install-plugins.sh
ENV GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false
USER 472
