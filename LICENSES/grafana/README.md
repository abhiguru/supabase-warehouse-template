# Grafana licence

Grafana (https://github.com/grafana/grafana) is licensed under the GNU Affero
General Public License, version 3 (AGPL-3.0-only). The complete licence text
is vendored in this directory as `LICENSE`, copied from the canonical
publication at https://www.gnu.org/licenses/agpl-3.0.txt and cross-checked
against the SPDX reference text (they differ only in the scheme of three
gnu.org and fsf.org URLs). Upstream keeps its copy at
https://github.com/grafana/grafana/blob/main/LICENSE.

This repository vendors no Grafana source or binaries. `docker/grafana/`
contains a build recipe that starts from the publisher's digest-pinned
`grafana/grafana:13.2.2` image, upgrades two Alpine libraries and replaces the
bundled plugins with publisher-signed, checksum-pinned releases. Anyone who
distributes the resulting image, or who modifies Grafana and lets users
interact with it over a network, must offer the corresponding source under
AGPL-3.0; see the Grafana section of `THIRD_PARTY_NOTICES.md`.
