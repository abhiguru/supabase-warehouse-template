import test from 'node:test';
import assert from 'node:assert/strict';
import * as W from '../scripts/watch.mjs';

// WH-115 (audit_write_failed) and WH-119 (sms_ceiling_reached): the two read-only database checks of scripts/watch.mjs against a fake compose.
const NOW = Date.parse('2026-11-07T10:00:00Z');
function world({ db = 0, psql = { status: 0, stdout: '' } } = {}) {
  const calls = [];
  const deps = {
    state: '/nonexistent-state', root: '/nonexistent-root', env: {}, now: () => NOW, readText: () => null,
    run: (command, args) => {
      const line = `${command} ${args.join(' ')}`;
      calls.push(line);
      if (line.includes('pg_isready')) return { status: db, stdout: '', stderr: '' };
      if (line.includes('psql')) return { stderr: '', ...psql };
      return { status: 1, stdout: '', stderr: 'unexpected' };
    },
  };
  return { calls, ctx: W.makeContext(deps, W.freshState(NOW)) };
}
const query = calls => calls.find(line => line.includes('psql'));

test('both checks are registered', () => {
  assert.ok(W.CHECKS.some(([name, fn]) => name === 'audit_writes' && fn === W.checkAuditWrites));
  assert.ok(W.CHECKS.some(([name, fn]) => name === 'sms_ceiling' && fn === W.checkSmsCeiling));
});

test('audit_write_failed: no failure in 24 hours passes; failures fail with the count, the tables and the latest time, repeated daily', () => {
  const clean = world({ psql: { status: 0, stdout: '0||\n' } });
  assert.deepEqual(W.checkAuditWrites(clean.ctx).map(r => [r.check, r.id, r.ok, r.summary]), [['audit_writes', 'audit_write_failed', true, 'Every audit row of the last 24 hours was written']]);
  assert.match(query(clean.calls), /audit_write_failures WHERE created_at > now\(\) - interval '24 hours'/);
  assert.match(query(clean.calls), /-U supabase_admin -d postgres/);
  const one = world({ psql: { status: 0, stdout: '1|grn|2026-11-07 09:00:00+00\n' } });
  const [single] = W.checkAuditWrites(one.ctx);
  assert.equal(single.ok, false);
  assert.equal(single.summary, '1 audit row could not be written in the last 24 hours (tables: grn; latest 2026-11-07 09:00:00+00). The saves went through.');
  assert.equal(single.repeatHours, 24);
  const many = world({ psql: { status: 0, stdout: '7|invoice,grn|2026-11-07 09:30:00+00\n' } });
  assert.match(W.checkAuditWrites(many.ctx)[0].summary, /^7 audit rows could not be written in the last 24 hours \(tables: invoice, grn; latest/);
  assert.match(W.checkAuditWrites(many.ctx)[0].detail, /audit_write_failures/);
});

test('audit_write_failed: not judged when the database is down; a query that fails or answers nonsense is an error of the check', () => {
  const down = world({ db: 1 });
  assert.equal(W.checkAuditWrites(down.ctx), null);
  assert.throws(() => W.checkAuditWrites(world({ psql: { status: 1, stdout: '', stderr: 'boom' } }).ctx), /audit failure query failed: boom/);
  assert.throws(() => W.checkAuditWrites(world({ psql: { status: 0, stdout: 'x|y|z\n' } }).ctx), /unexpected audit failure query output/);
});

// "hour used | hourly cap | day used | daily cap" as the query prints them.
const ceiling = out => W.checkSmsCeiling(world({ psql: { status: 0, stdout: `${out}\n` } }).ctx);

test('sms_ceiling_reached: below both ceilings passes; the hourly ceiling is 300 when unset and the daily one has none when unset', () => {
  assert.deepEqual(ceiling('10|60|20|300').map(r => [r.id, r.ok, r.summary]), [['sms_ceiling_reached', true, 'The SMS spending ceilings are not reached']]);
  assert.equal(ceiling('299||5000000|')[0].ok, true, 'unset hourly = 300, no daily ceiling');
  assert.equal(ceiling('300||0|')[0].ok, false, 'unset hourly = 300 reached at 300');
  assert.equal(ceiling('10|abc|0|xyz')[0].ok, true, 'values that are not whole numbers mean the default / none');
});

test('sms_ceiling_reached: reaching the hourly or the daily ceiling (>=) fails, naming each, repeated daily', () => {
  const [hour] = ceiling('60|60|3|300');
  assert.equal(hour.ok, false);
  assert.equal(hour.summary, 'The SMS spending ceiling is reached: 60 of 60 SMS sends this hour. Sign-in code requests are refused until it frees up.');
  assert.equal(hour.repeatHours, 24);
  const [day] = ceiling('1|60|300|300');
  assert.equal(day.summary, 'The SMS spending ceiling is reached: 300 of 300 SMS sends in 24 hours. Sign-in code requests are refused until it frees up.');
  const [both] = ceiling('61|60|301|300');
  assert.match(both.summary, /61 of 60 SMS sends this hour; 301 of 300 SMS sends in 24 hours/);
  assert.match(both.detail, /OPERATOR_INSTALL\.md, "SMS spending ceiling"/);
  assert.equal(ceiling('59|60|299|300')[0].ok, true, 'one below is fine');
});

test('sms_ceiling_reached: the query reads the counters of operator_prepare_otp; not judged when the database is down; nonsense is an error', () => {
  const w = world({ psql: { status: 0, stdout: '0||0|\n' } });
  W.checkSmsCeiling(w.ctx);
  assert.match(query(w.calls), /operator_otp_global_limit/);
  assert.match(query(w.calls), /otp_provider_attempts/);
  assert.match(query(w.calls), /otp_global_hourly_cap/);
  assert.match(query(w.calls), /otp_daily_provider_attempt_cap/);
  assert.equal(W.checkSmsCeiling(world({ db: 1 }).ctx), null);
  assert.throws(() => W.checkSmsCeiling(world({ psql: { status: 1, stdout: '', stderr: 'denied' } }).ctx), /SMS ceiling query failed: denied/);
  assert.throws(() => W.checkSmsCeiling(world({ psql: { status: 0, stdout: 'a|b|c|d\n' } }).ctx), /unexpected SMS ceiling query output/);
});
