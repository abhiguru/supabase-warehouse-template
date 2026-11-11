import { handle } from './handler.ts';

// The request handling lives in handler.ts so it can be tested without the runtime.
Deno.serve((req: Request) => handle(req));
