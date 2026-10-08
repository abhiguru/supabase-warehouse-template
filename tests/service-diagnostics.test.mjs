import test from 'node:test';
import assert from 'node:assert/strict';
import { diagnoseService, redactServiceLog } from '../scripts/service-diagnostics.mjs';

test('service diagnostics redact literal, URL and JSON encoded credentials', () => {
  const secret = 'fictional p@ss"\\word';
  const variants = [secret, encodeURIComponent(secret), JSON.stringify(secret).slice(1, -1)];
  const result = redactServiceLog(variants.join('\n'), { POSTGRES_PASSWORD: secret });
  for (const value of variants) assert.ok(!result.includes(value));
  assert.match(result, /REDACTED/);
});

test('service diagnostics hide derived JWTs and database URL passwords', () => {
  const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const token = [part({ alg: 'HS256' }), part({ sub: 'fictional' }), 'test_signature'].join('.');
  const text = `${token} ecto://admin:fictional-derived-secret@db/postgres`;
  const result = redactServiceLog(text, {});
  assert.ok(!result.includes('test_signature'));
  assert.ok(!result.includes('fictional-derived-secret'));
  assert.match(result, /@db\/postgres/);
});

test('service diagnostics preserve useful errors and handle empty values', () => {
  assert.equal(redactServiceLog('connection refused at db:5432', { JWT_SECRET: '', POSTGRES_HOST: 'db' }), 'connection refused at db:5432');
});

test('diagnostics refuse unknown services and failed ownership before reading logs', () => {
  const calls = [];
  const report = [];
  const options = { run: (...args) => { calls.push(args); return { status: 1 }; }, report: line => report.push(line) };
  diagnoseService('unrelated', options);
  assert.equal(calls.length, 0);
  diagnoseService('functions', options);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'bash');
  assert.ok(report.every(line => line.includes('unavailable')));
});

test('owned gateway diagnostics expose only selected state and redacted bounded logs', () => {
  const calls = [];
  const output = [];
  diagnoseService('functions', {
    run: (command, args) => {
      calls.push([command, args]);
      if (command === 'bash') return { status: 0, stdout: 'a'.repeat(64) };
      if (args[0] === 'inspect') return { status: 0, stdout: JSON.stringify({ Status: 'running', ExitCode: 0, OOMKilled: false, Health: { Status: 'healthy', Log: ['private'] } }) };
      return { status: 0, stdout: 'worker unavailable fictional-secret' };
    },
    env: () => ({ JWT_SECRET: 'fictional-secret' }),
    report: line => output.push(line),
  });
  assert.deepEqual(calls[0][1].slice(-4), ['ps', '-a', '-q', 'functions']);
  assert.deepEqual(calls[2][1].slice(0, 3), ['logs', '--tail', '60']);
  assert.ok(output.join('\n').includes('worker unavailable [REDACTED]'));
  assert.ok(!output.join('\n').includes('private'));
});
