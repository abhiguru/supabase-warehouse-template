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
