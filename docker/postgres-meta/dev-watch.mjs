import { watch } from 'node:fs';
import { spawn } from 'node:child_process';
import { extname } from 'node:path';

// Development only: restart the same Node/ts-node command on source changes.
const args = process.argv.slice(2);
if (!args.length) throw new Error('A Node entry point is required');
const ignored = new Set(['.git', 'node_modules', 'bower_components', '.nyc_output', 'coverage', '.sass-cache']);
const extensions = new Set(['.js', '.mjs', '.cjs', '.json', '.ts', '.tsx']);
let child, debounce, stopping = false, restarting = false, pending = false;
function launch() {
  child = spawn(process.execPath, args, { stdio: 'inherit' });
  child.on('error', () => shutdown(1));
}
async function stopChild() {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const current = child;
  await new Promise(resolve => {
    const timer = setTimeout(() => current.kill('SIGKILL'), 5000);
    current.once('exit', () => { clearTimeout(timer); resolve(); });
    current.kill('SIGTERM');
  });
}
async function restart() {
  if (stopping) return;
  if (restarting) { pending = true; return; }
  restarting = true;
  try { await stopChild(); if (!stopping) launch(); }
  finally { restarting = false; if (pending && !stopping) { pending = false; schedule(); } }
}
function schedule() {
  clearTimeout(debounce);
  debounce = setTimeout(() => { restart().catch(() => shutdown(1)); }, 100);
}
const watcher = watch(process.cwd(), { recursive: true }, (_event, filename) => {
  if (stopping) return;
  if (filename) {
    const parts = filename.split(/[\\/]/);
    if (parts.some(part => ignored.has(part))) return;
    const extension = extname(filename);
    if (extension && !extensions.has(extension)) return;
  }
  schedule();
});
watcher.on('error', () => shutdown(1));
async function shutdown(code) {
  if (stopping) return;
  stopping = true; watcher.close(); clearTimeout(debounce);
  await stopChild(); process.exitCode = code;
}
process.on('SIGINT', () => { shutdown(0).catch(() => { process.exitCode = 1; }); });
process.on('SIGTERM', () => { shutdown(0).catch(() => { process.exitCode = 1; }); });
launch();
