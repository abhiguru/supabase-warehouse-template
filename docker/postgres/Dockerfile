# The official PostgreSQL 18 image (Debian trixie, pinned by tag and index digest). The recipe replaces its gosu:
# the image ships gosu 1.19 built with an old Go toolchain, and Trivy reports fixable Go standard-library CVEs in
# that binary. The shim below does the same job with util-linux's setpriv, so no Go build is needed.
FROM postgres:18.6-trixie@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
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
