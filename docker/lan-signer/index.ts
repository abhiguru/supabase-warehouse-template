// The Deno entry of the LAN signer (WH-133), run by the edge runtime of the `functions` image as its main service
// (docker-compose.yml, service lan-signer: `start --main-service /home/deno/lan-signer`). Everything else is in signer.ts.
import { createSigner } from './signer.ts';

const handle = createSigner({
  env: name => Deno.env.get(name),
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  log: line => console.error(line),
});

Deno.serve(handle);
