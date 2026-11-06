import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// WH-109: tests/cups-check.sh starts the CUPS image. It may only ever do so without a network and against the null device; it must never
// print. (It runs in CI, needs Docker and an installed state, and is not run by `node --test`; this test guards how it is written.)
const script = readFileSync(new URL('./cups-check.sh', import.meta.url), 'utf8');
const code = script.split('\n').filter(line => !/^\s*#/.test(line)).join('\n');

test('cups-check.sh: the only device is file:/dev/null and every container runs without a network', () => {
  assert.deepEqual([...new Set([...code.matchAll(/(?:usb|ipp|ipps|http|https|socket|lpd|dnssd|file|serial|parallel|hp):\/\/?[^\s"']*|file:\/dev\/[^\s"']*/g)].map(match => match[0]))]
    .filter(uri => !/^http:\/\/localhost:631\/$/.test(uri)), ['file:/dev/null']);
  assert.match(code, /^device=file:\/dev\/null$/m);
  assert.match(code, /^run\(\) \{ docker run --rm --network none /m);
  // Every docker run goes through run(): none of its own, so none without --network none.
  assert.equal([...code.matchAll(/\bdocker run\b/g)].length, 1);
});

test('cups-check.sh never submits a job: no lp, lpr or print-capable command, no PRINTER_URI other than the device variable', () => {
  assert.doesNotMatch(code, /(^|[\s;|&'"(])(lp|lpr|lpq|lprm|cancel|cupsfilter)\s/m);
  assert.doesNotMatch(code, /Print-Job|ipptool|-d\s+\/dev|--device|--privileged|\/dev\/bus\/usb|--net(work)?[ =]+(?!none)/);
  for (const [, value] of code.matchAll(/PRINTER_URI="?([^"\s]*)"?/g)) assert.equal(value, '$device');
});
