# Maintenance calendar

What has to be done to this software, and when, over the next four years. Each row says where the obligation is checked and what
happens if nobody does it. Rows are sorted by the next date they fall due; a repeating obligation is listed at its next due date.
Dates marked **forecast** are an estimate from how the upstream project behaved before, not a published date: check them when the
month comes. The facility-side obligations are in
[Monthly host maintenance](OPERATOR_INSTALL.md#monthly-host-maintenance); the open items and accepted risks are in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md).

"Checked by": **CI** is a workflow in `.github/workflows`; **Watch** is an alert of the facility's monitoring checker
([MONITORING.md](MONITORING.md)); **by hand** means nothing reminds anyone.

| What | When | Checked by | If missed | Source |
| --- | --- | --- | --- | --- |
| Dependabot queue: base images, npm, Actions (the notices file in `THIRD_PARTY_NOTICES.md` is edited by hand with each) | weekly (Actions: monthly) | by hand (the pull request list) | Security updates wait; no image or package moves | `.github/dependabot.yml` |
| Chrome for Testing freshness of the PDF renderer | weekly, Monday | CI: `cft-freshness.yml` opens one issue when the pin is more than 14 days behind Stable. Warn only since 2026-10-26: `release.yml` never blocks a tag on it | The renderer's Chrome falls behind; the image scan cannot see it | `docs/CONTAINER_SECURITY.md`, "PDF renderer" |
| Keep-alive run (GitHub disables scheduled workflows after 60 days without repository activity; whether this run resets that clock is unverified) | monthly, the 1st; the owner opens the Actions tab after more than 45 days away | CI: `keep-alive.yml` | Every scheduled check stops, silently | `docs/PRODUCTION_DEPENDENCIES.md` |
| Host maintenance: apt (with Docker), restart `cloudflared`, Node.js minor, reboot | monthly, per facility | by hand; Watch: `cloudflared_old`, `host_node_eol`, `root_copy_stale` | Host packages age; a replaced binary keeps running the old one | `docs/OPERATOR_INSTALL.md`, "Monthly host maintenance" |
| `cloudflared`: Cloudflare supports only versions within a year of its newest; the tunnel runs with `--no-autoupdate` | yearly at the least | Watch: `cloudflared_old` at 11 months, and when a restart is due | The tunnel can stop working | `scripts/tunnel.sh` |
| PostgREST major | every 6 to 10 months | CI: Dependabot pull request | An unpatched API layer once the previous major is dropped | `docker/docker-compose.yml` |
| Glibc guard line of the database image: update it with each Debian glibc update | with each trixie glibc update (several a year) | CI: the migrations job fails on the bump | The database image does not build | `docker/postgres/Dockerfile` |
| Rebuild the images without the build cache (it keeps the operating-system packages of the day an image was first built) | now and then; the guide gives no cadence | by hand | OS packages stay at the first build day's | `docs/OPERATOR_INSTALL.md`, "Rerun and upgrade": `bash scripts/build-images.sh --no-cache` |
| After each facility upgrade: rerun `watch-timer.sh install` / `backup-usb.sh setup` when printed | each upgrade | Watch: `root_copy_stale` | Root-run copies stay on an earlier release's recipe | `scripts/upgrade.sh` |
| Backup key copy: confirm that the copy kept away from the host is still readable and held by someone who is still responsible | yearly, and whenever that person changes | by hand (Watch: `usb_backup` only says the copy was never confirmed) | Encrypted backups cannot be opened after the host is lost | `docs/OPERATOR_INSTALL.md`, "Backup key" |
| Per release: CHANGELOG, mobile contract (`MOBILE_REF`, `--live`), image scan without cache, release-candidate rehearsal | every release | by hand: `docs/RELEASE_CHECKLIST.md` | The release is not cut | `docs/RELEASE_CHECKLIST.md` |
| Support window of the previous minor line | 6 months after each new minor | by hand | Backports stop; the line is unsupported | `SECURITY.md` |
| Storage lock regeneration after a HIGH advisory in the Storage image's npm tree | unscheduled (two in 12 days in October 2026) | CI: every pull request is red until done | The Storage image is not rebuilt | `docker/storage/README.md` |
| storage-api move: a few minor versions, with the seeded drill (decision D6) | quarterly | CI: the Dependabot minor pull request fails `tests/storage-schema.test.mjs` until `ENV VERSION` and the freeze match the tag and `migrations-head.txt`, and the `migrations` job (`tests/migrations.sh`) until `migrations-head.txt` matches the image; the `storage-drill` job (weekly) rehearses the next tag | The pin drifts by hundreds of upstream releases and the one catch-up move is days of work | `.github/dependabot.yml`, `docker/storage/README.md`, `tests/storage-drill.sh` |
| Node image drops the `alpine3.23` variant when Alpine 3.25 ships: move `docker/storage/Dockerfile` to the variant that exists | **forecast** Nov to Dec 2026 | by hand | The Storage runtime stops receiving Node updates, silently | `docker/storage/Dockerfile` |
| Image-scan exceptions: renew or remove the six entries | **2027-01-15**, then every 90 days at most | by hand: `npm run scan:images` and the release checklist fail on an expired entry (CI does not run the scan) | No release can pass the checklist | `docker/image-exceptions.json`, `docs/CONTAINER_SECURITY.md` |
| nginx stable branch moves to 1.32 (1.30.0 came out 2026-04-15) | **forecast** April 2027, then every April | by hand; `tests/gateway-config.test.mjs` names the pinned version | The gateway runs a branch that no longer gets fixes | `docker/nginx/Dockerfile` |
| Node.js 22 end of life on the host | **2027-04-30** | Watch: `host_node_eol`, 60 days before | The host runs a Node.js without security fixes; `doctor` still accepts it | `NODE_END_OF_LIFE` in `scripts/watch.mjs` |
| Ubuntu 22.04 end of standard support, under CUPS (only where printing is on) | **2027-04 to 05** | by hand | Print service on an unpatched base | `docker/cups/Dockerfile` |
| Debian 14 (forky) ships; the official `python` images drop their bookworm variants (sensor bridge) | **forecast** mid-2027 | by hand | The sensor bridge stops receiving Python updates | `docker/sensor-bridge/Dockerfile` |
| Python minor for the sensor bridge (now the 3.15 line; 3.16 expected October 2027; 3.15 ends **forecast** October 2031) | each October | CI: the Dependabot pull request fails until wheels exist | Small | `docker/sensor-bridge/Dockerfile` |
| Alpine 3.23 end of life (Storage runtime stage); Alpine 3.24 follows **forecast** 2028-05 | **2027-11-01** | by hand | The Storage runtime stage has no OS fixes | Alpine release branches |
| Node.js 24 end of life in the Storage and PDF renderer images, and on a host that follows it | **2028-04-30** | Watch: `host_node_eol` (host); by hand (images) | Images without Node.js fixes | `NODE_END_OF_LIFE` in `scripts/watch.mjs` |
| Debian 12 (bookworm) long-term support ends: functions final stage and sensor bridge; upstream edge-runtime must leave bookworm first | **2028-06-30** | by hand | The functions image has no OS fixes | `docker/edge-runtime/Dockerfile` |
| Build and drill the scripted PostgreSQL major move (`upgrade.sh --major`, decision D8) on seeded data | 2028 | by hand | The 2029 move is attempted untried | `docs/OPERATOR_INSTALL.md`, "Collation changes" |
| **The PostgreSQL major move: one scripted dump and restore at every facility, one planned downtime each (decision D8).** The database's Debian base is never changed in place | **2029 H1** | by hand | Past mid-2029 the `postgres:18-trixie` image stops getting patches, or a glibc change reorders every text index | decision D8 |
| Node.js 26 end of life on the host | **2029-04-30** | Watch: `host_node_eol` | As for 22 | `NODE_END_OF_LIFE` in `scripts/watch.mjs` |
| Debian 15 ships; `postgres:18-trixie` stops (the database and PDF renderer base) | **forecast** mid-2029 | by hand | The database image gets no patches (see the major move above) | docker-library/postgres |
| PostgreSQL 18 end of life | **2030-11** | by hand | No database fixes | postgresql.org versioning policy |

Review this file at every release: remove the rows whose date has passed, move a forecast to a date when upstream publishes it,
and add the next obligation the release introduces.
