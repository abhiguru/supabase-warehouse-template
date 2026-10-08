import { serve } from "https://deno.land/std@0.192.0/http/server.ts"

serve(async () => {
  return new Response(
    `"Hello from Edge Functions!"`,
    { headers: { "Content-Type": "application/json" } },
  )
})
