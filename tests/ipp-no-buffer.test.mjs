import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

// WH-109 review finding 2: the edge runtime gives user code no global Buffer, and functions/vendor/ipp.mjs used it without importing it,
// so every CUPS print, status check, monitor poll and cancel threw "Buffer is not defined" there. Node has the global, so a plain
// test cannot see it: this one runs the vendored library in a child process with the global removed.
const program = `
  import { Buffer as NodeBuffer } from 'node:buffer';
  delete globalThis.Buffer;
  if (typeof Buffer !== 'undefined') throw new Error('Buffer is still defined');
  const { default: ipp } = await import(process.argv[1]);
  const printer = ipp.Printer('http://cups:631/printers/LQ1310_RAW');
  const message = printer._message('Print-Job', { 'operation-attributes-tag': { 'requesting-user-name': 'warehouse-grn', 'job-name': 'x', 'document-format': 'application/vnd.cups-raw' }, data: NodeBuffer.from([0x1b, 0x43, 0x00, 0x06, 0x0a, 0x0c, 0x0d, 0x88, 0xff]) });
  const bytes = ipp.serialize(message);
  const parsed = ipp.parse(bytes);
  console.log(JSON.stringify({ length: bytes.length, operation: parsed.operation, user: parsed['operation-attributes-tag']['requesting-user-name'] }));
`;

test('functions/vendor/ipp.mjs serializes and parses a message with no global Buffer (as in the edge runtime)', () => {
  const library = new URL('../functions/vendor/ipp.mjs', import.meta.url).href;
  const run = spawnSync(process.execPath, ['--input-type=module', '-e', program, library], { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
  assert.equal(run.status, 0, run.stderr);
  const answer = JSON.parse(run.stdout.trim().split('\n').at(-1));
  assert.deepEqual([answer.operation, answer.user], ['Print-Job', 'warehouse-grn']);
  assert.ok(answer.length > 60, `${answer.length} bytes`);
});

test('the library imports Buffer itself (a banner import), so it does not depend on the runtime', async () => {
  const { readFileSync } = await import('node:fs');
  assert.match(readFileSync(new URL('../functions/vendor/ipp.mjs', import.meta.url), 'utf8').slice(0, 600), /import \{[^}]*\bBuffer\b[^}]*\} from ['"]node:buffer['"]/);
});
