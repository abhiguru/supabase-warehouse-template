import { serve } from 'https://deno.land/std@0.192.0/http/server.ts';
import { handle } from './handler.ts';

// The request handling lives in handler.ts so it can be tested without the runtime.
serve((req: Request) => handle(req));
