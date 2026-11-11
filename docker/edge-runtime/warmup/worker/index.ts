// The same `node:` modules the functions import (_shared/client-info.ts, _shared/print-transport.ts, vendor/ipp.mjs).
import { Buffer } from 'node:buffer';
import { createRequire } from 'node:module';
import { isIP } from 'node:net';

Deno.serve(() => new Response(`warm ${isIP('1.2.3.4')} ${Buffer.from('a').length} ${typeof createRequire}`));
