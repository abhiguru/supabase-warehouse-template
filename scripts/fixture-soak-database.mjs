// Optional read-only postconditions for this explicitly prepared fictional soak.
// Not loaded by ordinary installation; requires the unchanged core fixture guard.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import {
  resolve as resolveFixture,
  isAbsolute as absoluteFixture,
} from "node:path";
import { pathToFileURL } from "node:url";
const fixtureCheckout = process.env.WAREHOUSE_FIXTURE_CHECKOUT;
assert.ok(
  fixtureCheckout && absoluteFixture(fixtureCheckout),
  "Explicit owning fixture checkout required",
);
const { operatorFixture } = await import(
  pathToFileURL(resolveFixture(fixtureCheckout, "tests/operator-fixture.mjs"))
    .href
);
import { isAbsolute, dirname } from "node:path";
import { lstatSync } from "node:fs";
process.umask(0o077);
const { env } = operatorFixture();
const [mode, file] = process.argv.slice(2);
assert.ok(["snapshot", "verify", "session"].includes(mode));
assert.ok(file && isAbsolute(file));
const parent = lstatSync(dirname(file));
assert.ok(
  parent.isDirectory() &&
    !parent.isSymbolicLink() &&
    parent.uid === process.getuid() &&
    (parent.mode & 0o077) === 0,
  "Privately owned output directory required",
);
if (existsSync(file)) {
  const st = lstatSync(file);
  assert.ok(
    st.isFile() &&
      !st.isSymbolicLink() &&
      st.uid === process.getuid() &&
      (st.mode & 0o077) === 0,
  );
}
function sql(query) {
  const r = spawnSync(
    "docker",
    [
      "exec",
      "-i",
      "-e",
      "PGPASSWORD",
      `${env.WAREHOUSE_PROJECT_NAME}-db-1`,
      "psql",
      "-X",
      "-qAt",
      "-U",
      "supabase_admin",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
    ],
    {
      input:
        "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY; " +
        query +
        " COMMIT;",
      env: { ...process.env, PGPASSWORD: env.POSTGRES_PASSWORD },
      encoding: "utf8",
      timeout: 30000,
    },
  );
  assert.equal(r.status, 0, "Private read-only SQL guard failed");
  return JSON.parse(r.stdout.trim());
}
const data = sql(
  `SELECT json_build_object('receipts',(SELECT coalesce(json_agg(x ORDER BY x.gr_no),'[]') FROM (SELECT g.gr_no,count(*) lines,sum(t.qty) qty,sum(t.stock) stock FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id=g.id WHERE g.gr_no IN ('FXF101','FXF102','FXF200','FXF301','FXF302') GROUP BY g.gr_no) x),'counts',json_build_object('goodsreceived',(SELECT count(*) FROM public.goodsreceived),'receipt_lines',(SELECT count(*) FROM public.goodsreceived_trl),'dispatch',(SELECT count(*) FROM public.dispatch),'dispatch_lines',(SELECT count(*) FROM public.dispatch_trl),'invoices',(SELECT count(*) FROM public.invoice),'images',(SELECT count(*) FROM public.grn_images),'storage',(SELECT count(*) FROM storage.objects)),'invoice',(SELECT json_agg(to_jsonb(i)-'updated_at') FROM public.invoice i WHERE gr_no='IRP05' AND deleted_at IS NULL));`,
);
for (const number of ["FXF101", "FXF102", "FXF200", "FXF301", "FXF302"]) {
  const row = data.receipts.find((x) => x.gr_no === number);
  assert.ok(row);
  assert.equal(Number(row.lines), 1);
  assert.equal(Number(row.qty), number.startsWith("FXF3") ? 4 : 10);
  assert.equal(
    Number(row.stock),
    number === "FXF200" ? 6 : number.startsWith("FXF3") ? 4 : 7,
  );
}
if (mode === "snapshot") {
  assert.ok(!existsSync(file), "Never overwrite evidence");
  writeFileSync(file, JSON.stringify(data, null, 2) + "\n", { mode: 0o600 });
  console.log("PASS private read-only business baseline captured");
}
if (mode === "verify") {
  assert.deepEqual(data, JSON.parse(readFileSync(file)));
  console.log(
    "PASS reserved receipt quantities, business counts and saved invoice unchanged",
  );
}
if (mode === "session") {
  assert.ok(!existsSync(file));
  const sessions = sql(
    `SELECT json_build_object('verifiedCount',(SELECT count(*) FROM public.otp_verifications WHERE phone_number='919888888871' AND verified_at IS NOT NULL),'accessSeconds',coalesce((SELECT value::int FROM warehouse_security.auth_config WHERE key='access_seconds'),3600),'sessions',(SELECT coalesce(json_agg(json_build_object('id',s.id,'hash',s.token_hash,'created',s.created_at,'expires',s.expires_at) ORDER BY s.created_at),'[]') FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id=s.user_id WHERE p.mobile='919888888871'));`,
  );
  writeFileSync(file, JSON.stringify(sessions, null, 2) + "\n", {
    mode: 0o600,
  });
  console.log(
    "PASS private native administrator session metadata snapshot; no credentials logged",
  );
}
