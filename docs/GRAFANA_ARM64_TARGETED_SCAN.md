# Grafana arm64 targeted vulnerability scan

The [manual workflow](../.github/workflows/grafana-arm64-targeted-scan.yml) builds
the checked-out `docker/grafana/Dockerfile` and `plugins.lock` on a native
`ubuntu-24.04-arm` runner. The recipe pins the Grafana base image by digest and
the bundled plugin archives by checksum. The workflow tags its disposable local
image with the GitHub run ID and attempt, checks that Docker reports
`linux/arm64`, and scans that image with checksum-verified Trivy 0.74.0.

From the repository's **Actions** tab, select **Grafana targeted arm64
vulnerability scan**, choose **Run workflow**, and select `main`. The job runs
only for a manual dispatch on `main`. Equivalently, use
`gh workflow run grafana-arm64-targeted-scan.yml --ref main`.

The scan uses `--scanners vuln --severity HIGH,CRITICAL --ignore-unfixed
--list-all-pkgs --format json`, matching the all-profile scan's vulnerability
selection. The workflow validates the report's image identity, schema, and
versioned package inventory. Known findings are counted in the job summary and
the three-day `grafana-arm64-targeted-scan-<run>-<attempt>` artifact. The artifact
contains `report.json`, `summary.txt`, and `build.txt` with the repository commit
and verified image architecture. Build, scanner, and report-validation errors
fail the job; findings alone do not.

This is dated evidence for the one Grafana arm64 candidate. It does not replace
the strict full image inventory or prove that the production image gate passes.
The image and temporary scan files are removed at the end of the job. No
application services are started.
