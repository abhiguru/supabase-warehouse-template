# Grafana licence

Grafana (https://github.com/grafana/grafana) is licensed under the GNU Affero
General Public License, version 3 (AGPL-3.0-only). The canonical licence text
is published at https://www.gnu.org/licenses/agpl-3.0.txt and in the upstream
repository at https://github.com/grafana/grafana/blob/main/LICENSE.

The licence text is not reproduced in this directory because no verified copy
was available offline when this notice was written; obtain it from the
canonical URL above and include it with any rebuilt image you distribute.

This repository vendors no Grafana source or binaries. `docker/grafana/`
contains a build recipe that starts from the publisher's digest-pinned
`grafana/grafana:13.2.2` image, and a retained `go.mod`/`go.sum` patch
(`core-thrift-0.24.0.patch`, described in `docker/grafana/PATCH.md`). See the
Grafana section of `THIRD_PARTY_NOTICES.md` for the redistribution
obligations.
