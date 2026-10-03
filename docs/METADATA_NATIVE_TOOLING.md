# Metadata development tooling dependency correction

The full postgres-meta audit reported eight high findings through cpy-cli and
nodemon. The review source replaces these two development dependencies with
Node filesystem helpers. Production dependencies, all 170 production lock
entries, and every retained lock entry remain byte-for-byte unchanged. No audit
waiver, forced upgrade, API, schema or running warehouse change is involved.

`copy-build-assets.mjs` copies top-level regular SQL files and the format worker
with their original flat destinations and exact bytes. Pinned upstream v0.99.0
has no raw SQL files: TypeScript compiles its 20 SQL modules. The worker copy is
verified separately; synthetic regression coverage checks SQL copying/rebuilds.
`dev-watch.mjs` recursively observes source changes, ignores dependency/cache
paths, debounces restarts and stops its child on shutdown, with a five-second
termination fallback. It runs the existing Node/ts-node entry point. Node>=20
on Linux supports this watcher; the documented campaign uses Node22.23.3.

Reproduce from this review source:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run check:container-dependencies
```

For an isolated image, build `docker/postgres-meta` under an unused local tag;
the Dockerfile verifies the upstream archive checksum, applies the declared
Fastify/Vitest patches, installs the pinned lock without lifecycle scripts,
checks TypeScript, builds, executes three selected upstream suites, and prunes
development dependencies. Observe the campaign actor locks and resource limits.
Do not replace a running warehouse image from this command alone.

Evidence on the owned VM is private under
`/home/jay/warehouse-install-private/vm-campaign-20261001/metadata-native-tooling0110-01`:
prior full audit8 high, current full audit0; lock preservation proof; backend
source tests105/105; pinned clean-source check/build and upstream tests12/12;
exact worker bytes/20 compiled SQL modules; source scan and current mobile
contract. The first post-build observer incorrectly required raw SQL files and
failed; that evidence is retained alongside the corrected actual-source check.
No complete backend installation, runtime metadata acceptance, mobile dependency
closure, final candidate freeze, new soak or delayed expiry is established here.

## Exact isolated image result

Clean backend9c11104 built amd64 image
`sha256:dc02e8f3ecd25b33798dddb9c6dc355fa82f58d49d4faf0d5732262adf16e786`
under unused tag `warehouse-fixture-metadata-9c11104-vm2026100110-01:local`.
Build/check/selected upstream suites PASS in the Dockerfile. The exact image
then PASSed root200, health200 and absent-route404 via actual Fastify injection,
with the exact source lock and worker bytes. The bounded probe uses no network,
read-only filesystem, dropped capabilities, no ports/warehouse volumes or
credentials, and512MiB/2CPU limits. Reusable source is
`tests/meta-image-candidate-smoke.mjs`; pass it on stdin to the image's Node
entry point using `--input-type=module` and the Dockerfile's declared user.

Attempt1 incorrectly overrode the image user withUID1000 and failed package
import resolution because the root-owned manifest is private. Attempt2 used
the declared root identity and stdin rather than changing any permissions.
Both attempts remain preserved. This verifies the declared runtime user only;
it does not establish arbitrary-user compatibility or installed-service health.
Private aggregate: `metadata-native-tooling-image-final-proof01.json`; build
and smoke records: `metadata-image-build0110-01`. The supervisor exited0 with
no restart. No image installation, running tag/volume replacement or complete
backend reproduction follows from this result.
