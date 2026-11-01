// The best-effort "Warehouse WSL stop" task of scripts/windows/register-tasks.ps1 and the stop.sh flag it uses. PowerShell is not
// available here, so the script is checked as text; stop.sh is run for real against a stub Compose wrapper.
import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const ps1 = readFileSync(join(root, 'scripts/windows/register-tasks.ps1'), 'utf8');

test('register-tasks.ps1 registers "Warehouse WSL stop" on System event 1074 (User32), 90 s limit, running stop.sh --on-host-shutdown in the distro, never started at registration', () => {
  assert.match(ps1, /\$StopName = 'Warehouse WSL stop'/);
  assert.match(ps1, /Provider\[@Name=''User32''\] and EventID=1074/);
  assert.match(ps1, /Path="System"/);
  assert.match(ps1, /MSFT_TaskEventTrigger/);
  assert.match(ps1, /New-ScheduledTaskSettingsSet -ExecutionTimeLimit \(New-TimeSpan -Seconds 90\)/);
  assert.match(ps1, /\$stopArguments = "-d \$Distro -- env WAREHOUSE_STATE_DIR=\$State bash \$Checkout\/stop\.sh --on-host-shutdown"/);
  assert.match(ps1, /Register-WarehouseTask \$StopName \$action \$settings \(New-ShutdownTrigger\) -NoStart/);
  assert.match(ps1, /if \(\$NoStart\) \{ return \}\n\s+try \{\n\s+Start-ScheduledTask/, 'the stop task is not started when registered');
  // Only with both paths, and only plain Linux paths (they go into an argument line of an elevated task).
  assert.match(ps1, /\[string\]\$Checkout,\n\s+\[string\]\$State/);
  assert.match(ps1, /'-Checkout and -State go together/);
  assert.match(ps1, /\^\/\[A-Za-z0-9\._\/-\]\+\$/);
  // The existing tasks are untouched: still two-minute repeating, unlimited.
  assert.match(ps1, /sleep infinity/);
  assert.match(ps1, /New-ScheduledTaskSettingsSet -ExecutionTimeLimit \(\[TimeSpan\]::Zero\)/);
});

function runStop(args) {
  const scratch = mkdtempSync(join(tmpdir(), 'stop-flag-'));
  try {
    const checkout = join(scratch, 'checkout');
    mkdirSync(join(checkout, 'scripts'), { recursive: true });
    copyFileSync(join(root, 'stop.sh'), join(checkout, 'stop.sh'));
    copyFileSync(join(root, 'scripts/operator-lock.sh'), join(checkout, 'scripts/operator-lock.sh'));
    writeFileSync(join(checkout, 'scripts/compose.sh'), '#!/usr/bin/env bash\necho "$@" > "$WAREHOUSE_STATE_DIR/compose-args"\n', { mode: 0o755 });
    const state = join(scratch, 'state');
    mkdirSync(join(state, 'config'), { recursive: true });
    const result = spawnSync('bash', [join(checkout, 'stop.sh'), ...args], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: state } });
    return { result, held: existsSync(join(state, 'config/stopped-by-operator')), args: existsSync(join(state, 'compose-args')) ? readFileSync(join(state, 'compose-args'), 'utf8') : null };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('stop.sh holds the stack down; stop.sh --on-host-shutdown stops it the same way but leaves no hold file', () => {
  const plain = runStop([]);
  assert.equal(plain.result.status, 0, plain.result.stderr);
  assert.equal(plain.held, true);
  const shutdown = runStop(['--on-host-shutdown']);
  assert.equal(shutdown.result.status, 0, shutdown.result.stderr);
  assert.equal(shutdown.held, false, 'a host shutdown that is followed by a start must not keep the stack down');
  assert.equal(shutdown.args, plain.args);
  assert.match(shutdown.args, /--profile \* down --remove-orphans/);
});
