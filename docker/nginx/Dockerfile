# The gateway: plain nginx from the official image, replacing Kong (docs/CONTAINER_SECURITY.md, "Gateway limits and routes").
#
# nginx 1.30 is the stable branch. The alpine-slim variant is used because it has the smallest package inventory of the
# official variants (21 Alpine packages, about 13 MB; Trivy reported no HIGH or CRITICAL row on 1.30.6, against 60 on the
# Debian-based 1.30.6-trixie) and it still holds everything the configuration uses: the realip, gzip and limit_req
# modules, HTTP/2 and the envsubst of the image's /docker-entrypoint.d/20-envsubst-on-templates.sh. Move to the next
# stable branch (1.32) once a year; read the index digest with `docker buildx imagetools inspect nginx:<tag>`.
FROM nginx:1.30.6-alpine-slim@sha256:dede8895648b461178c3bc604f7eed4423efe5220b2c4d839f5eb3d34ac3f8f7

# Alpine security updates for the whole image, as the other recipes do for their packages. The image's own default
# server is removed: nothing listens on port 80.
RUN apk upgrade --no-cache \
    && rm -f /etc/nginx/conf.d/default.conf

# nginx.conf replaces the image's: one worker, no `user` directive (the master runs as the nginx user already), the pid
# file and every temporary path under /tmp, so the root file system can be read-only, and the logs on stdout/stderr.
COPY nginx.conf api-http.conf api-locations.conf cors-headers.conf /etc/nginx/
# Only these variables are put into the templates (see the filter below). A template is rendered into
# /etc/nginx/conf.d at start by the image's entrypoint; Compose mounts a tmpfs there. The image holds the public server only.
# The LAN server (lan/gateway-lan.conf.template, the gateway-lan service of docker-compose.yml) is not copied in: Compose mounts
# it over templates/gateway.conf.template of that one container, so the public container has no LAN listener at all.
COPY templates/ /etc/nginx/templates/
# 18-require-env.sh runs before the image's own scripts: it refuses to start on a missing or odd value.
COPY --chmod=0755 docker-entrypoint.d/ /docker-entrypoint.d/

# A regular expression on the NAMES of the environment variables; only a name that matches in full is replaced, so
# $remote_addr, $uri and the other nginx variables in the templates stay as they are. LAN_CIDR is set in the gateway-lan container
# only (the allow list of the LAN server); the public container has none, so nothing is replaced there.
ENV NGINX_ENVSUBST_FILTER="^(CORS_ALLOWED_ORIGIN|ANON_KEY|SERVICE_ROLE_KEY|LAN_CIDR)$"
# The user `nginx` (101) of the image. Ports 8000 (the public server) and 8080 (the LAN server of gateway-lan) need no capability.
USER 101:101
EXPOSE 8000 8080
