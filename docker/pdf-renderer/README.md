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
| 503 | queue full, too many bytes in flight, shutting down, browser cannot be launched, running job hit a crash or kill |
| 504 | the 25 s deadline passed |
| 500 | anything else, including a result that is not a complete PDF |

Early refusals (413 by header, 503 at admission, 400 for a wrong content type) are answered at once, before any of the
body is read. The server then reads and throws away the rest of the upload without buffering it, and closes the
connection only when the body has ended, after 10 s, or when more than the larger of 48 MiB and the declared length has
arrived. A plain `fetch` client that is still uploading therefore reads the status and the JSON body instead of getting a
network error (`test/fixtures/client.mjs` checks this from a Node 24 container). `Expect: 100-continue` is honoured: a
request that would be refused is refused before the `100 Continue`, and an admitted request gets it only when it is
granted a slot.

`printBackground=false` removes the `html` and `body` backgrounds only, exactly as Gotenberg does: Gotenberg always
injects `print-color-adjust: exact`, which makes Chrome print every other element's background regardless of the flag, and
this service injects the same style. Backgrounds on other elements still print with `printBackground=false`. This is
intended parity, not a bug.

### `GET /health`

Answers immediately from a background probe (`Browser.getVersion` every 2 s, 5 s timeout), never from a live check.

- 200 `{"status":"up"|"restarting","chromium":{"version","jobs","restarts","queue","inflightBytes","memoryMB","containerMB"}}`.
  `restarting` covers boot, planned restarts and the first relaunch after a crash. Jobs queue while it lasts.
- 503 `{"status":"down", ...}` after two failed probes in a row (the browser is killed and relaunched at the fifth failed probe), while launches
  keep failing or the browser is crash-looping, and while the process is shutting down.

## Limits and queueing

| What | Value | Env |
| --- | --- | --- |
| Body size | 48 MiB exactly is accepted; refused by `Content-Length` before reading (413) above that. A missing length (chunked) is counted while streaming and aborted at the limit | `MAX_BODY_MB` |
| Admission | queued + in-flight declared bytes at most 100 MiB, queue at most 10; otherwise 503 before the body is read. A chunked body counts as a large (8 MiB) one | `MAX_QUEUE_MB`, `MAX_QUEUE` |
| Concurrency | 2 for bodies under 8 MiB; a body of 8 MiB or more runs alone and nothing starts beside it. No second job starts while Chrome's own memory is at or above 500 MB (large decoded images, shared memory) | `CONCURRENCY`, `SOLO_BODY_MB`, `SECOND_JOB_CHROME_MB` |
| Deadline | 25 s from request arrival (reading, queue and render). A queued job whose client disconnected is dropped | `DEADLINE_MS` |
| Waiting for a browser | a restart or drain makes queued jobs wait (bounded by their own deadline); only when the browser cannot be launched at all does a queued job get 503, after 15 s | `RESTART_WAIT_MS` |
| Server timeouts | `keepAliveTimeout` 65 s, `headersTimeout` 66 s | fixed |

## Browser lifecycle

- One browser, started at boot (the first real render is logged with `"cold": true`).
- Every launch uses a fresh `--user-data-dir=/tmp/profiles/<launch-id>`, removed after the old process has exited.
- Memory is measured in two ways. **Chrome's own process-tree RSS** decides restarts and kills: a planned restart after
  100 jobs, or between jobs when it is at least 650 MB; the watchdog kills the browser when it reaches 1100 MB during a job
  (`RESTART_MEMORY_MB`, `KILL_MEMORY_MB`). **The container's cgroup working set** (`memory.current` minus `inactive_file`)
  is only an admission guard: while at least 1200 MiB is in use and a job is running, the next body is not read until
  that job ends (`CONTAINER_GUARD_MB`). It never restarts or kills Chrome, so Node's own memory cannot cause a restart.
- Planned restarts drain first (health says `restarting`) for at most deadline + 5 s, then kill what is left. Queued jobs
  wait through the drain and the relaunch; they are bounded only by their own deadline.
- There is one transition at a time. A crash, watchdog kill, stuck page or disconnect during a drain fails the running jobs,
  kills that browser, and lets the restart in progress launch the single replacement.
- Crash (disconnect, tab crash, process exit, a page that will not close after the deadline, the watchdog): running jobs get
  503; queued jobs wait for the relaunched browser. The first crash relaunches at once; repeats wait 1, 2, 4, 8 s. Crashes
  alone never end the process. Only 5 failed launches in a row do: the process exits non-zero so Docker restarts the
  container.
- Health probe: a real `Browser.getVersion` round trip on a CDP session (not puppeteer's cached `version()`) every 2 s,
  5 s timeout. `/health` says `down` (503) from the second failure in a row; the browser is killed and replaced after the
  fifth (`PROBE_KILL_AFTER`), or comes back to `up` if it answers again (checked with SIGSTOP/SIGCONT in the integration test).
- SIGTERM: stop admitting (503), finish queued and running jobs for up to 20 s, close the browser, then let responses that
  are still being written finish (idle connections are closed as they become idle; whatever is left after 5 s is cut) and
  exit 0. A 30 MB PDF in flight reaches the client complete. Compose should set `stop_grace_period: 30s`. A crash during
  shutdown fails queued jobs at once.
- A client is answered as soon as the PDF is read; the page and context are closed afterwards and the slot is freed only
  when that cleanup is done.

## Per-job behaviour and parity switches

Defaults are the hardened setup; each switch changes one thing, for parity tests against Gotenberg.

| Env | Values (default first) | Meaning |
| --- | --- | --- |
| `RENDERER_CONTEXT` | `perjob`, `shared` | new browser context per job, or a new tab in the default context (Gotenberg) |
| `RENDERER_JS` | `off`, `on` | `Emulation.setScriptExecutionDisabled` before navigation |
| `RENDERER_LOAD` | `auto`, `intercept`, `file` | `intercept`: serve `index.html` from memory at `http://render.invalid/index.html`; `file`: write it to `/tmp/jobs/<id>/` and open the `file://` URL (directory removed afterwards); `auto` (default): `file` for bodies of 8 MiB or more, `intercept` for the rest |
| `RENDERER_CSP` | `on`, `off` | in `intercept` mode with scripts off, send `Content-Security-Policy: default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'` with the document, which blocks `data:` frames and objects. The four captured documents render identically with and without it |
| `RENDERER_FONTS_READY` | `on`, `off` | await `document.fonts.ready`, capped at 2 s, never fatal |

Order of one job: (context, tab) then scripts off, `Fetch.enable`, navigate and wait for `load`, inject the print-colour
style by `Runtime.evaluate`, fonts wait, media emulation, `Page.printToPDF` (`ReturnAsStream`, `generateTaggedPDF:false`,
`generateDocumentOutline:false`), `IO.read` until eof, `IO.close`, then page and context closed in `finally`.

Every request except the main document is blocked: other navigations (meta refresh, links, frames, popups) are answered
`204 No Content`, so they are cancelled and the document stays; all other requests (http, https, `file:`, ws, ...) fail with
`BlockedByClient`. `data:` images and fonts inside the document load (Chrome never pauses them in the Fetch domain). Chrome
also starts with `--host-resolver-rules=MAP * ~NOTFOUND`; because an IP literal bypasses that rule, the integration test
points a hostile page at a real listener on the Docker network and asserts it sees no connection. Known limit: an
`about:srcdoc` frame still renders (it cannot load anything), and in `file` mode (large bodies) there is no CSP, so a
`data:` iframe renders too; it cannot reach the network either.

Large bodies: the HTML is kept as bytes (never decoded to a string), the body is parsed in one streaming pass, and bodies
of 8 MiB or more go through a file, so no base64 copy crosses the DevTools pipe. Measured with two 49 MB bodies at once in a
1.5 GiB container: `memory.peak` 511 MiB in file mode against 730 MiB in intercept mode.

## Container

Run it with these flags (the image works under all of them). **The memory limit must be 1.5 GiB**
(`mem_limit: 1536m` and `memswap_limit: 1536m` in compose): the thresholds above are sized for it. A 48 MP JPEG is a small
body but decodes to a bitmap of about 200 MB, and with `--disable-dev-shm-usage` Chrome's shared memory is counted as
tmpfs/shmem (up to about 440 MiB seen).

```
docker run --read-only --tmpfs /tmp:size=256m --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1536m --memory-swap 1536m pdf-renderer
```

- tini is PID 1 (`init` is not needed in compose). The user is uid 10001.
- `HOME=/tmp/home`, `TZ=UTC`, `LANG=LC_ALL=C.UTF-8`, XDG directories under `/tmp`; the service creates them at boot.
- Base `node:24-trixie-slim` pinned by digest; amd64 only (the build fails fast otherwise).
- Fonts: `fonts-liberation fonts-liberation2 fonts-dejavu fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
  fonts-crosextra-carlito fonts-crosextra-caladea fonts-opensymbol`, named without versions because Debian's security
  revisions replace and remove older ones (the Gotenberg targets carry `fonts-opensymbol` 4:102.12+LibO26.2.2.2-3~bpo13+1
  from trixie-backports; trixie's own build has the same `opens___.ttf` path). Debian's
  default fontconfig `conf.d` plus `fontconfig/100-gotenberg.conf` (byte-identical in Gotenberg 8.25, 8.32 and 8.37), then
  `fc-cache -sf` as the last font step. The build fails unless the sorted `fc-list` file list hashes to
  `bb94b4513fc8a1aba5b2d7949632f3fc9311cad45ad288dc204555be0814986d` (`ARG FONT_FILELIST_SHA256`), the value of both
  targets, computed as `targets/probe.sh` does. A Debian update that changes the font file list
  fails the build; the golden-PDF job (`tests/golden-pdf`) catches any change in the rendered pages.
- `MALLOC_ARENA_MAX=2` limits glibc arena growth in the Node process.
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
- `test/render.test.mjs` runs `render.mjs` against a scripted fake puppeteer: the order of CDP calls, the print parameters,
  the request filter, file mode, cleanup.
- `test/integration.sh` builds the image (under `flock`), runs it with the hardening flags above on a private Docker network
  and checks: health and the hung-Chrome probe (SIGSTOP gives 503, SIGCONT or a kill recovers); a fixture render (2 pages,
  fonts, untagged, A4, footer "Page 1 of 2", landscape); hostile pages pointed at a real listener by IP literal (JS off,
  JS on with fetch/XHR/WebSocket/beacon/popup, file mode) with zero connections seen; the `data:` frame CSP; 400 cases; a
  48 MiB + 1 body giving 413; a Node 24 `fetch` client that fills the queue and must read 503/413/400 JSON bodies; a SIGTERM
  during a ~30 MB render that must deliver the complete PDF and exit 0; the font file-list hash; no leftover files.
  `IMAGE=name test/integration.sh` skips the build; `CHS_VERSION` and `CHS_SHA256` select another browser.

## Logs

One JSON line per event on stdout: `listening`, `launch`, `restart_begin`, `browser_down`, `launch_backoff`, `watchdog_kill`,
`probe_failed`, `shutdown_begin`, and one `job` line per request (`id`, `bytes`, `pages`, `queueMs`, `renderMs`, `outcome` = `ok`, `error`, `dropped` or `refused`, `code`, and
`cold` on the first render after each browser launch). Documents, field values and file names are never logged.
