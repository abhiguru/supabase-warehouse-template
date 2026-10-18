# pdf-renderer

A small HTML to PDF service. It replaces Gotenberg for the warehouse edge functions. One Node process drives one
chrome-headless-shell (CHS) through puppeteer-core and answers `POST /render`.

- Input: the HTML our own code builds (optionally with a header and footer template). No URLs, no other file types.
- Output: one PDF, fully buffered, checked to start with `%PDF-` and end with `%%EOF`.
- The service never reaches the network: every request the page makes is blocked, scripts are off, and Chrome
  resolves no host names.

## API

### `POST /render` (port 3000, `multipart/form-data`)

Files (the part's filename decides; the form field name is not checked):

| Filename | Required | Notes |
| --- | --- | --- |
| `index.html` | yes, exactly once | the document |
| `header.html` | no | Chrome header template |
| `footer.html` | no | Chrome footer template (`pageNumber`, `totalPages`, ... classes work as in Gotenberg) |

Any other filename, or a duplicate, gives 400. A missing header or footer becomes `<html><head></head><body></body></html>`;
`displayHeaderFooter` is on only when one of them is sent.

Fields (all optional; any other field gives 400, and so does a duplicate):

| Field | Default | Rule |
| --- | --- | --- |
| `paperWidth`, `paperHeight` | 8.27, 11.69 (A4 inches) | positive, at most 100 |
| `marginTop`, `marginRight`, `marginLeft` | 0.39, 0.55, 0.55 | `>= 0` |
| `marginBottom` | 0.55, or 1.0 when `footer.html` is sent | `>= 0`; margins must leave room on the page |
| `landscape` | `false` | `true` or `false` |
| `printBackground` | `true` | `true` or `false` |
| `scale` | `1` | 0.1 to 2 |
| `emulatedMediaType` | `print` | `print` or `screen` |
| `preferCssPageSize` | `true` | `true` or `false` |
| `waitDelay` | absent | accepted only as `0`, `0s` or `0ms` |

Responses:

- 200: `Content-Type: application/pdf`, with `Content-Length`.
- Errors are JSON `{"error": "...", "code": <status>}`:

| Status | When |
| --- | --- |
| 400 | invalid input (see above, or a body that is not valid multipart) |
| 413 | body over the limit |
| 503 | queue full, too many bytes in flight, shutting down, browser unavailable, browser crashed or killed |
| 504 | the 25 s deadline passed |
| 500 | anything else, including a result that is not a complete PDF |

Early refusals (413, 503, and 400 for a wrong content type) carry `Connection: close`. The server answers first, then
discards the rest of the upload for up to 5 s so the client can read the answer.

Known Gotenberg-compatible behaviour: the print-colour style (`print-color-adjust: exact`) is always injected, so with
`printBackground=false` only the `html` and `body` backgrounds are removed; backgrounds on other elements still print.

### `GET /health`

Answers immediately from a background probe (`Browser.getVersion` every 2 s, 5 s timeout), never from a live check.

- 200 `{"status":"up"|"restarting","chromium":{"version","jobs","restarts","queue","inflightBytes","memoryMB"}}`.
  `restarting` covers boot, planned restarts and the first relaunch after a crash. Jobs queue while it lasts.
- 503 `{"status":"down", ...}` after two failed probes in a row (the browser is then killed and relaunched), while launches
  keep failing or the browser is crash-looping, and while the process is shutting down.

## Limits and queueing

| What | Value | Env |
| --- | --- | --- |
| Body size | 48 MB; refused by `Content-Length` before reading (413). A missing or false length is counted while streaming and aborted at the limit | `MAX_BODY_MB` |
| Admission | queued + in-flight bytes at most 100 MB, queue at most 10; otherwise 503 before the body is read | `MAX_QUEUE_MB`, `MAX_QUEUE` |
| Concurrency | 2; a body of 8 MB or more runs alone | `CONCURRENCY`, `SOLO_BODY_MB` |
| Deadline | 25 s from request arrival (reading, queue and render). A queued job whose client disconnected is dropped | `DEADLINE_MS` |
| Waiting for a browser | a queued job gets 503 after 15 s without a browser | `RESTART_WAIT_MS` |
| Server timeouts | `keepAliveTimeout` 65 s, `headersTimeout` 66 s | fixed |

## Browser lifecycle

- One browser, started at boot (the first real render is logged with `"cold": true`).
- Every launch uses a fresh `--user-data-dir=/tmp/profiles/<launch-id>`, removed after the old process has exited.
- Planned restart: after 100 jobs, or between jobs when memory is at least 650 MB (cgroup v2 `memory.current` minus
  `inactive_file`; process-tree RSS if the cgroup is not readable). The service drains first (health says `restarting`), for
  at most deadline + 5 s, then kills what is left.
- Watchdog: at 900 MB during a job, the browser is killed. Running and queued jobs get 503 and the browser relaunches.
- Crash (disconnect, tab crash, process exit, two failed probes, a page that will not close after the deadline): running
  and queued jobs get 503 and the browser relaunches at once. A repeat crash, or a failed launch, waits 1, 2, 4, 8 s.
  After 5 failures in a row the process exits non-zero so Docker restarts the container.
- SIGTERM: stop admitting (503), finish queued and running jobs for up to 20 s, close the browser, exit 0. Compose should
  set `stop_grace_period: 30s`.

## Per-job behaviour and parity switches

Defaults are the hardened setup; each switch changes one thing, for parity tests against Gotenberg.

| Env | Values (default first) | Meaning |
| --- | --- | --- |
| `RENDERER_CONTEXT` | `perjob`, `shared` | new browser context per job, or a new tab in the default context (Gotenberg) |
| `RENDERER_JS` | `off`, `on` | `Emulation.setScriptExecutionDisabled` before navigation |
| `RENDERER_LOAD` | `intercept`, `file` | serve `index.html` from memory at `http://render.invalid/index.html`, or write it to `/tmp/jobs/<id>/` and open the `file://` URL (directory removed afterwards) |
| `RENDERER_FONTS_READY` | `on`, `off` | await `document.fonts.ready`, capped at 2 s, never fatal |

Order of one job: (context, tab) then scripts off, `Fetch.enable`, navigate and wait for `load`, inject the print-colour
style by `Runtime.evaluate`, fonts wait, media emulation, `Page.printToPDF` (`ReturnAsStream`, `generateTaggedPDF:false`,
`generateDocumentOutline:false`), `IO.read` until eof, `IO.close`, then page and context closed in `finally`.

In `intercept` mode every request except the main document and `data:` URLs is failed with `BlockedByClient` (http, https,
`file:`, ws, ...). Chrome also starts with `--host-resolver-rules=MAP * ~NOTFOUND`.

## Container

Run it with these flags (the image works under all of them):

```
docker run --read-only --tmpfs /tmp:size=256m --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1g --memory-swap 1g pdf-renderer
```

- tini is PID 1 (`init` is not needed in compose). The user is uid 10001.
- `HOME=/tmp/home`, `TZ=UTC`, `LANG=LC_ALL=C.UTF-8`, XDG directories under `/tmp`; the service creates them at boot.
- Base `node:24-trixie-slim` pinned by digest; amd64 only (the build fails fast otherwise).
- Fonts: `fonts-liberation fonts-liberation2 fonts-dejavu fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
  fonts-crosextra-carlito fonts-crosextra-caladea`, Debian's default fontconfig `conf.d` plus `fontconfig/100-gotenberg.conf`
  (byte-identical in Gotenberg 8.25, 8.32 and 8.37), then `fc-cache -sf` as the last font step.
- npm, corepack and yarn are removed from the final image (the files stay in the base layer).
- Labels: `pdf-renderer.chs-version`, `pdf-renderer.puppeteer-core-version`, `pdf-renderer.git-sha`
  (and `org.opencontainers.image.revision`).

Build:

```
docker build -t pdf-renderer --build-arg GIT_SHA="$(git rev-parse HEAD)" docker/pdf-renderer
```

## Bumping Chrome (CHS)

1. Look up the version in Chrome for Testing: `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json`
   (Stable) or `known-good-versions-with-downloads.json`.
2. Download
   `https://storage.googleapis.com/chrome-for-testing-public/<VERSION>/linux64/chrome-headless-shell-linux64.zip` and run
   `sha256sum` on it.
3. Change both `ARG CHS_VERSION` and `ARG CHS_SHA256` in the `Dockerfile` (or pass both as `--build-arg`).
4. If puppeteer-core is bumped too, change `package.json`, `package-lock.json` and `ARG PUPPETEER_CORE_VERSION`; the build checks
   that the installed version equals the ARG. Use the puppeteer-core release whose pinned Chrome is the CHS major version
   (25.14.0 pins 155.0.8059.79).
5. Run `npm test` and `test/integration.sh`, then the document parity comparison.

Pinned builds (zip SHA-256, linux64 chrome-headless-shell):

| CHS | SHA-256 |
| --- | --- |
| 155.0.8059.84 (default, Stable on 2026-10-17) | `a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c` |
| 147.0.7727.116 | `8b3584f747a3a7155e1f99dc712dfd0576eedafe3da331819ccd52e17bee61a6` |

## Tests

- `npm test` runs `node --test test/*.test.mjs` with a fake browser layer (no Chrome needed): multipart parsing and every
  400 case, 413 by header and by stream, admission 503, concurrency and the solo rule, deadline and dropped clients, crash and
  backoff, planned restarts, the watchdog, health states, SIGTERM drain, leftover files, PDF validation, and a check that
  logs hold no HTML.
- `test/integration.sh` builds the image (under `flock`), runs it with the hardening flags above and checks health, a fixture
  render (page count, fonts), a hostile page (remote `img`, `link`, `script`, `iframe`, inline script: render still 200, script
  did not run), 400 cases, a 48 MB + 1 body giving 413, no leftover files and a clean SIGTERM. `IMAGE=name test/integration.sh`
  skips the build; `CHS_VERSION` and `CHS_SHA256` select another browser.

## Logs

One JSON line per event on stdout: `listening`, `launch`, `restart_begin`, `browser_down`, `launch_backoff`, `watchdog_kill`,
`shutdown_begin`, and one `job` line per request (`id`, `bytes`, `pages`, `queueMs`, `renderMs`, `outcome`, `code`, and
`cold` on the first render). Documents, field values and file names are never logged.
