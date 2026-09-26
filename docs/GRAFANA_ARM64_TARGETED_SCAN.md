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

This produces dated evidence for both native Grafana candidate architectures.
The 2026-09-26 plugin-pruned candidate has been scanned locally on amd64 only;
the native arm64 candidate job remains pending. These targeted reports do not
replace the strict full image inventory or prove that the production image gate
passes. Each job removes its own image and temporary scan files. No application
services are started.
