# Remove unused bundled plugins and replace the four retained plugins with
# complete, publisher-signed, checksum-pinned releases.
FROM grafana/grafana:13.2.4@sha256:dbbc38ea21103cefb50396340cd88afec779c7e070b0a7bf5a75b4ce46651d3f

ARG TARGETARCH
USER root
COPY plugins.lock install-plugins.sh /tmp/
RUN apk add --no-cache --upgrade 'libcrypto3>=3.5.8-r0' 'libssl3>=3.5.8-r0' \
    && TARGETARCH="$TARGETARCH" sh /tmp/install-plugins.sh \
    && rm /tmp/plugins.lock /tmp/install-plugins.sh
ENV GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false
USER 472
