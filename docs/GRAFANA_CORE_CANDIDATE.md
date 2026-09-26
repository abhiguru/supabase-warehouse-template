# Grafana 13.2.2 core Thrift candidate

The current Grafana 13.2.2 image has a fixed HIGH finding for Apache Thrift
`v0.23.1-0.20260429145742-d2acd3c49e58` in the core Go executable.
[Apache's advisory](https://www.openwall.com/lists/oss-security/2026/07/24/33)
includes the Go binding and identifies 0.24.0 as the fix. This prototype
rebuilds only the Grafana core executable; the image remains based on the
publisher's pinned 13.2.2 digest and keeps the frontend and signed plugin
archives from the image recipe checked out when the script runs. The 2026-09-25
result below used the earlier recipe with 13 plugins. The 2026-09-26 combined
core and nine-plugin recipe has native amd64 build, smoke and scan evidence;
its combined arm64 validation remains pending.

Source and build inputs:

- Grafana release tag `v13.2.2`, peeled commit
  `3db12332b66497c31f8ad2a5fb0eb0fe0ca05a7e`.
- `docker/grafana/core-thrift-0.24.0.patch` changes only the root `go.mod`
  Thrift requirement and adds its Go checksum entries to `go.sum`.
- Go 1.26.6 builder image
  `golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36`.
- Publisher runtime image
  `grafana/grafana:13.2.2@sha256:ac461fb352abc50da10a51c7d02462e9c05488f11f53f14b3ad79a8145f638a0`.
- Existing `plugins.lock` versions and publisher archive SHA-256 values.

On a native amd64 or arm64 Docker host, choose a persistent absolute
evidence directory and run, for example:

```bash
GRAFANA_CORE_EVIDENCE_DIR=/path/to/grafana-core-evidence \
  scripts/build-grafana-core-candidate.sh
```

The script verifies the Grafana source commit, applies the fixed patch,
compiles with Grafana's `make build-go`, checks `go version -m` for Thrift
0.24.0, then builds `warehouse-grafana-core:candidate`. The evidence directory
retains the source commit, builder and runtime image digests, patch and
plugin-lock checksums, native architecture, compilation and image-build logs,
Go build metadata, portable binary SHA-256, image ID, and proof that the image
contains the same binary. The script removes only its temporary source checkout
on exit. It sets CPU and memory limits on the builder container; the host must
have sufficient disk for Grafana's Go dependencies.

To check the resulting image without rebuilding the ordinary recipe, run
`GRAFANA_SMOKE_IMAGE=warehouse-grafana-core:candidate bash scripts/grafana-check.sh`.
The smoke script starts isolated temporary services and checks startup,
publisher plugin signatures, provisioning, and live queries. Run the existing
Trivy HIGH/CRITICAL image scan on the candidate for each architecture, then
the complete 19-image strict scan before changing production readiness.
Retain the raw scan JSON alongside the build evidence:

```bash
trivy image --quiet --scanners vuln --severity HIGH,CRITICAL \
  --ignore-unfixed --list-all-pkgs --exit-code 0 --format json \
  --output /path/to/grafana-core-evidence/report.json \
  warehouse-grafana-core:candidate
```

This candidate changes the provenance of the **core binary** to a local
build. Its 2026-09-25 scan still found eight HIGH plugin findings. The pruned
plugin recipe is a separate change; their combined amd64 result is below, and
their combined arm64 build, smoke check and image scan remain pending.
Keep the strict image gate open until that image passes without ignoring findings.

## Combined core and pruned-plugin amd64 result, 2026-09-26

At repository commit `f8fd060e4aada22a6bcc8c1a945f9c182e8bb7b1`, an isolated
native amd64 build used the pinned Grafana 13.2.2 source, Thrift patch, builder
and runtime images with the nine-plugin pruned recipe. The core binary SHA-256
is `232812b972f3a532faaed837a1389328785afa6ffa1a548cdf48c0d827c9dda9`,
and the image contains that same binary. The candidate image
`warehouse-grafana-core:20260926-amd64-core-prune` has ID
`sha256:c0ab4d7141a31a2bfc277d5d476050e35739fd981c1ed6969dc6ed5173c77306`.
Its build metadata and exact-image scan inventory show Apache Thrift 0.24.0 in
Grafana core; the core Thrift HIGH finding is absent.

The exact-image Trivy 0.74.0 scan at the fixed HIGH/CRITICAL threshold reports
**2 HIGH, 0 CRITICAL**: CVE-2026-84445 in `google.golang.org/grpc` v1.83.1 in
each of the publisher-signed Prometheus and PostgreSQL plugin executables.
The image-report validator correctly rejects the image. The existing smoke
check passed Grafana health, all nine publisher signatures, provisioning and
live Prometheus/PostgreSQL queries. The build artifacts succeeded; automatic
cleanup of a read-only Go module cache failed, and the task's scratch cleanup
subsequently passed. Raw evidence is retained in
`/home/gcswebserver/ws/grafana-core-prune-evidence-20260926-amd64`.
The exact-image Trivy JSON SHA-256 is
`557e47f411d90cbc712e781efa29998291475c56c6209b4deef52675ec858c18`.

The [Prometheus](https://grafana.com/grafana/plugins/prometheus/) and
[PostgreSQL](https://grafana.com/grafana/plugins/grafana-postgresql-datasource/)
catalog pages still offered versions 13.2.1 and 13.0.3 respectively on this
date; no compatible signed release with the [gRPC
fix](https://github.com/grpc/grpc-go/security/advisories/GHSA-2v4p-qf9q-27wj)
was verified. When Grafana publishes one, inspect the signed archive's Go
build metadata, pin its version and per-architecture checksums, then repeat
native smoke and image scans. PostgreSQL is still supplied by the pinned base
image, outside `plugins.lock`, so a fixed signed release must explicitly replace
that bundled directory. The combined arm64 candidate and the full 19-image
strict inventory have not been run; production readiness is unchanged.

## Local amd64 result, 2026-09-25

An isolated native amd64 build completed with Go 1.26.6 and selected Thrift
0.24.0. `go version -m` on the 496 MiB binary confirms both. Its SHA-256 is
`232812b972f3a532faaed837a1389328785afa6ffa1a548cdf48c0d827c9dda9`.
The final labeled image `warehouse-grafana-core:20260925-amd64` has ID
`sha256:6aa99a9d614826464b243abc0f8891dd330efb7dffaa2d851ae0a8c176776e29`.
The image reports Grafana 13.2.2.

Trivy 0.74.0 scanned that exact image with `--scanners vuln --severity
HIGH,CRITICAL --ignore-unfixed --list-all-pkgs`. The report contains **8 HIGH,
0 CRITICAL**. This scan no longer reports the single Apache Thrift HIGH
finding in Grafana's main executable; all eight reported HIGH findings are
in six publisher-signed plugin executables. The image report validator
correctly rejects the image because findings remain. The existing Grafana
smoke check passed: healthy startup, 13 valid publisher-signed plugins under
the recipe at that date, provisioning, and live Prometheus/PostgreSQL queries.

The first cold compile took about six minutes with a four-CPU, 10 GiB
container limit. The Go module and build caches reached about 3.7 and
4.9 GiB, respectively; the source checkout was about 324 MiB and the final
image about 2.18 GB. Leave substantially more than 14 GB of free disk for
Docker layers and Trivy data.

The end-to-end build script was rerun with explicit persistent evidence and
existing Go caches; it reproduced the same binary and image IDs. The raw
Trivy JSON SHA-256 is
`85efd53a7cfbd0758ce1d751f22535e3f737eae37842f7da5623596676043bb9`.

## Remaining native candidate validation

Before activating this prototype in the ordinary image recipe, run a matrix
on **native** amd64 and arm64 Linux runners with at least 16 GiB RAM and 25 GiB
free disk. Each job should verify `uname -m`, build from the pinned tag with
this script, and save the source commit, builder digest, `go version -m`,
binary SHA-256, image ID,
and architecture, run the existing Grafana smoke check, and produce a Trivy
0.74.0 JSON report. Validate report schema and image identity, assert that
the single Apache Thrift HIGH finding in Grafana's main executable is absent
at this scan threshold, and show every remaining HIGH finding in
the job summary and artifact. Findings must continue to fail the separate
strict production image gate. Once arm64 has matching evidence, the complete
19-image strict inventory can be rerun after the plugin fixes.

The manual research recipe merged through
[PR #63](https://github.com/abhiguru/supabase-warehouse-template/pull/63) at
`3eda9686f71b48860464d74e9b42c3e3490fb239`; its
[exact-main CI](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36128411899)
passed. That CI tested the ordinary Grafana recipe on native amd64 and arm64
runners. It did **not** build this candidate on arm64 or run this proposed
candidate matrix.

The [manual combined-candidate workflow](../.github/workflows/grafana-core-pruned-candidate.yml)
requires explicit labels for larger, ephemeral GitHub-hosted native amd64 and
arm64 runners; it does not use a self-hosted Docker daemon. Each selected runner
must have at least four CPUs, 16 GiB RAM and 25 GiB free on the work, temporary,
Docker and evidence filesystems. The 25 GiB preflight threshold is a
conservative margin for the build, image layers and scan data.
[Standard GitHub-hosted Linux runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
have 14 GB total storage and fail this preflight. No qualified larger native
arm64 runner is currently available, so the combined arm64 matrix has not run.
Supply qualified hosted runner labels before dispatching the workflow.
