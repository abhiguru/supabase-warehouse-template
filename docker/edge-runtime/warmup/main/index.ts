// Build-time warm-up (docker/edge-runtime/Dockerfile): starts one user worker so the runtime downloads and caches what a
// `node:` import needs (the @types/node typings) into the image, and a new functions container then boots with no internet.
Deno.serve(async (req: Request) => {
  const worker = await EdgeRuntime.userWorkers.create({
    servicePath: '/opt/warmup/worker',
    memoryLimitMb: 150,
    workerTimeoutMs: 60000,
    noModuleCache: false,
    envVars: [],
  });
  return await worker.fetch(req);
});
