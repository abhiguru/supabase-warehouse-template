// Live check, against the disposable CI installation (tests/operator-fixture.mjs), that the API roles' statement timeouts reach
// real requests: PostgREST runs with PGRST_DB_CONFIG=true (docker/docker-compose.yml), so a call made as `anon` is cut by the
// database after 3 seconds (SQLSTATE 57014, "canceling statement due to statement timeout"), while the same call as
// `service_role` runs on under the login role's 8 seconds. Without the option PostgREST never reads the role settings and both
// run for the full time. tests/database-settings.test.mjs only reads the shipped files; this proves the behaviour.
// A temporary function is created in `public` and dropped again whatever happens.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { operatorFixture } from './operator-fixture.mjs';

const { env, base, anon } = operatorFixture();
const sql = query => {
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: `${query}\n`, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, `private fixture SQL failed: ${result.stderr?.slice(-400)}`);
  return result.stdout.trim();
};
const probe = async (key, seconds) => {
  const started = Date.now();
  const response = await fetch(`${base}/rest/v1/rpc/ci_timeout_probe`, { method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_seconds: seconds }), signal: AbortSignal.timeout(30000) });
  const text = await response.text();
  let data = null; try { data = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, ok: response.ok, data, text, ms: Date.now() - started };
};

try {
  sql(`CREATE OR REPLACE FUNCTION public.ci_timeout_probe(p_seconds integer) RETURNS integer LANGUAGE plpgsql
         AS $$ BEGIN PERFORM pg_sleep(p_seconds); RETURN 1; END $$;
       GRANT EXECUTE ON FUNCTION public.ci_timeout_probe(integer) TO anon, service_role;
       NOTIFY pgrst, 'reload schema';`);
  // PostgREST reloads its schema cache on the notification; wait until the function is served.
  let ready = false;
  for (let attempt = 0; attempt < 40 && !ready; attempt++) {
    ready = (await probe(anon, 0)).ok;
    if (!ready) await new Promise(done => setTimeout(done, 500));
  }
  assert.ok(ready, 'PostgREST did not serve the temporary probe function within 20 s');

  const cut = await probe(anon, 5);
  assert.equal(cut.ok, false, `anon ran a 5 s call to the end (HTTP ${cut.status}): the 3 s timeout does not reach PostgREST requests`);
  assert.match(cut.text, /57014|statement timeout/, `anon was refused for another reason: HTTP ${cut.status} ${cut.text.slice(0, 200)}`);
  assert.ok(cut.ms >= 2500 && cut.ms < 5000, `anon was cut after ${cut.ms} ms, not at about 3000`);

  const kept = await probe(env.SERVICE_ROLE_KEY, 5);
  assert.ok(kept.ok, `service_role was cut as well (HTTP ${kept.status} ${kept.text.slice(0, 200)}): the limit must belong to anon`);
  assert.ok(kept.ms >= 4500, `service_role finished after ${kept.ms} ms`);
  console.log(`anon was cut after ${cut.ms} ms (57014); service_role ran the same call for ${kept.ms} ms.`);
} finally {
  sql(`DROP FUNCTION IF EXISTS public.ci_timeout_probe(integer); NOTIFY pgrst, 'reload schema';`);
}
