# The official PostgreSQL 18 image (Debian trixie, pinned by tag and index digest). The recipe replaces its gosu:
# the image ships gosu 1.19 built with an old Go toolchain, and Trivy reports fixable Go standard-library CVEs in
# that binary. The shim below does the same job with util-linux's setpriv, so no Go build is needed.
FROM postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
# Debian published fixes for the Kerberos libraries (krb5 1.21.3-5+deb13u2) and zlib after the 18.7 base image was built, and
# Trivy reports them as HIGH/CRITICAL rows with a fix, which the image scan gate (docker/image-exceptions.json) does not
# allow. Upgrade only these named packages, as docker/nginx/Dockerfile does with `apk upgrade`. No libc package is in the
# list (libc6, libc-bin and locales stay as the base image has them), so the collation guard below keeps passing; it
# runs after this layer and fails the build if one of them ever changed. Remove a name when the base image carries the fix.
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade libgssapi-krb5-2 libkrb5-3 libk5crypto3 libkrb5support0 zlib1g \
    && rm -rf /var/lib/apt/lists/*
# Delete the base image's binary in a layer of its own first: an image scanner (Trivy) reads each layer, and a file that is
# only overwritten would still be reported as the Go binary it was.
RUN rm -f /usr/local/bin/gosu
COPY --chmod=0755 gosu /usr/local/bin/gosu
# `gosu nobody id` proves the shim runs; the second line proves it drops to postgres the way the entrypoint relies on
# (user and group ids, the supplementary group ssl-cert, HOME, and a non-root process).
RUN gosu nobody id \
    && test "$(gosu postgres id -u):$(gosu postgres id -g)" = "$(id -u postgres):$(id -g postgres)" \
    && test "$(gosu postgres sh -c 'echo $HOME')" = "$(getent passwd postgres | cut -d: -f6)" \
    && test "$(gosu postgres id -G | tr ' ' '\n' | sort -n | paste -sd' ')" = "$(id -G postgres | tr ' ' '\n' | sort -n | paste -sd' ')" \
    && postgres --version | grep -q 'PostgreSQL) 18\.'
# Collation guard. Text indexes depend on glibc's collation of en_US.UTF-8; a base image whose libc6 or locales
# package differs (a Dependabot digest bump) can reorder strings and corrupt every text index until a REINDEX. The
# versions below are the ones the data of the facilities was built with. A bump that changes them fails this build:
# check the glibc changelog for collation changes, plan a REINDEX if there are any, then update the line below.
# The base is never changed in place (a new Debian release, a different glibc line): that happens only through the dump-and-restore major
# move planned for 2029 H1. `node scripts/doctor.mjs` fails when the recorded collation version differs (docs/OPERATOR_INSTALL.md, "Collation changes").
RUN set -eu; \
    expected='libc-bin 2.41-12+deb13u4 libc6 2.41-12+deb13u4 locales 2.41-12+deb13u4'; \
    actual="$(dpkg-query -W -f='${Package} ${Version}\n' libc6 libc-bin locales | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"; \
    [ "$actual" = "$expected" ] || { echo "Refused: the base image's glibc or locales differ from the recorded versions (docker/postgres/Dockerfile). Expected '$expected', found '$actual'. Collations may have changed: see the comment above this line." >&2; exit 1; }
