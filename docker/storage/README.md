# Storage image recipe

The recipe takes the publisher's `supabase/storage-api` image, with its
precompiled application and native modules, and installs this directory's
`package.json` and `package-lock.json` over it. The manifest is the
publisher's own (without `scripts` and `devDependencies`) plus the dependency
versions raised for security fixes.

## Moving to a new publisher tag

The manifest belongs to one tag. Changing the `FROM` line alone installs the
old tag's dependency set under the new application.

1. Read the new image's manifest and lockfile:
   `docker run --rm --entrypoint cat supabase/storage-api:<tag> /app/package.json`
   (and `/app/package-lock.json`).
2. Start from those two files. Drop `scripts` and `devDependencies`, then
   carry over the raised versions and the `overrides` block from the current
   `package.json`, leaving out any the new tag already meets.
3. `npm install --package-lock-only --ignore-scripts` in this directory.
4. Set the tag and digest in `Dockerfile`, build with `--no-cache`, and scan
   the result (`trivy image --severity HIGH,CRITICAL`). Raise or override what
   the scan still names and repeat from step 3.
5. Update the version in `docs/CONTAINER_SECURITY.md`, then run the operator
   API tests, which upload and read photos and documents.

2026-10-12, v1.79.14 to v1.80.2: the new tag's lockfile pinned fastify 5.11.2
and `@fastify/busboy` 3.1.1, both with HIGH findings, so `fastify` is raised
to `^5.12.2` and busboy is overridden to 3.2.1.

2026-10-13, two moderate advisories in the locked runtime: `@fastify/busboy`
3.2.1 ([GHSA-gxm5-99cw-xjw9](https://github.com/advisories/GHSA-gxm5-99cw-xjw9),
a bare line feed kept in a multipart filename; the uploader here does not use
that filename for the object key) and `fast-copy` 4.0.2
([GHSA-jggr-w7fw-pc2j](https://github.com/advisories/GHSA-jggr-w7fw-pc2j),
stack exhaustion on deeply nested values; it arrives through `pino-pretty` and
no request-controlled path to it was found). The busboy override is raised to
3.2.3 (3.2.2 is the fix; 3.2.3 adds only a fix for a hang on a multipart
epilogue) and `fast-copy@^4` is overridden to 4.1.2. The override is needed:
a plain lock regeneration keeps 4.0.2, which satisfies `pino-pretty`'s
`^4.0.0`, and a Dependabot bump to 4.1.2 was lost when the lock was rebuilt for
v1.80.2. The lock was regenerated with npm 11.12.1
(`npx -y npm@11.12.1 install --package-lock-only --ignore-scripts
--lockfile-version 2`) and changed only those two packages; `npm audit
--omit=dev` reports 0 vulnerabilities. The image build and the upload tests
run in CI's install job; the `--no-cache` build and Trivy scan (step 4) are
for the release checklist.
