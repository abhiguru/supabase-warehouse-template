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
