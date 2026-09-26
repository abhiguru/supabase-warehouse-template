# Grafana native targeted vulnerability scan

The [manual workflow](../.github/workflows/grafana-arm64-targeted-scan.yml) builds
the checked-out `docker/grafana/Dockerfile` and `plugins.lock` on native
`ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) runners. The recipe pins
the Grafana base image by digest and the retained plugin archives by checksum.
Each job tags a disposable image with the GitHub run ID, attempt and architecture,
checks that Docker reports the expected platform, and scans that exact image
with checksum-verified Trivy 0.74.0.

After the candidate is committed to a branch, select **Grafana targeted
vulnerability scan** in the repository's **Actions** tab, choose **Run
workflow**, and select that branch. Equivalently, use
`gh workflow run grafana-arm64-targeted-scan.yml --ref <candidate-branch>`.

The scan uses `--scanners vuln --severity HIGH,CRITICAL --ignore-unfixed
--list-all-pkgs --format json`, matching the all-profile scan's vulnerability
selection. The workflow validates the report's image identity, schema, and
versioned package inventory, image ID and platform. Known findings are counted
in the job summary and separate three-day
`grafana-<arch>-targeted-scan-<run>-<attempt>` artifacts. Each artifact contains
`report.json`, `summary.txt`, and `build.txt` with the repository commit and
verified image architecture. Build, scanner, and report-validation errors fail
the job; findings alone do not.

The [2026-09-26 native targeted run
36217948795](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36217948795)
passed at exact branch commit `d71f094` for the plugin-pruned candidate. Its
amd64 image was
`sha256:a3e89ab77dcee9b7e27334660f0ae2c648b5dfb6cf01df9181a312b924166ab3`;
its arm64 image was
`sha256:8a9c4af83e68e93ebd9724b4d5ded8ccafa2aa9d4c76390c1971897b12fc2a62`.
Both reports have **3 HIGH, 0 CRITICAL**: CVE-2026-43871 in Grafana core and
CVE-2026-84445 in each retained Prometheus and PostgreSQL plugin. Workflow
success records valid targeted evidence; the strict production image gate
remains open. These reports do not replace the full image inventory. Each job
removes its own image and temporary scan files. No application services are
started.
