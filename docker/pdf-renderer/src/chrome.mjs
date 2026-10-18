// The real browser layer: launches chrome-headless-shell through puppeteer-core and wraps it in the
// small "engine" interface the supervisor uses. The supervisor tests replace this module with a fake.
//
// Engine interface:
//   id, pid, version
//   render(job, { signal, deadlineAt }) -> Promise<{ pdf: Buffer, pages: number }>
//   probe() -> Promise<string>                 (Browser.getVersion)
//   close() -> Promise<void>                   (graceful, falls back to kill)
//   kill() -> Promise<void>                    (SIGKILL the browser's process group; resolves once it has exited)
//   exited -> Promise<void>                    (resolves after the process is gone)
//   onDown: (reason) => void                   (set by the supervisor; called on disconnect or process exit)
//   memoryBytes() -> Promise<number|null>      (process-tree RSS, used when cgroup numbers are unavailable)

import fs from 'node:fs/promises';
import puppeteer from 'puppeteer-core';
import { renderJob } from './render.mjs';

// Gotenberg's flags (read from its running Chromium) plus chromedp's defaults, as in the prototype.
export const CHROME_FLAGS = [
  '--show-component-extension-options', '--enable-gpu-rasterization', '--no-default-browser-check', '--disable-pings',
  '--media-router=0', '--disable-dev-shm-usage', '--enable-remote-extensions', '--disable-features=site-per-process,Translate,BlinkGenPropertyTrees',
  '--disable-prompt-on-repost', '--use-mock-keychain', '--no-zygote', '--no-first-run', '--headless',
  '--disable-pdf-tagging', '--disable-client-side-phishing-detection', '--disable-renderer-backgrounding', '--disable-sync',
  '--enable-automation', '--font-render-hinting=none', '--disable-background-networking', '--disable-ipc-flooding-protection',
  '--safebrowsing-disable-auto-update', '--disable-backgrounding-occluded-windows', '--mute-audio', '--disable-default-apps',
  '--force-color-profile=srgb', '--disable-popup-blocking', '--metrics-recording-only', '--password-store=basic', '--hide-scrollbars',
  '--disable-hang-monitor', '--no-sandbox', '--enable-features=NetworkService,NetworkServiceInProcess',
  '--disable-background-timer-throttling', '--disable-breakpad', '--disable-extensions',
  '--host-resolver-rules=MAP * ~NOTFOUND',
];

export async function processTreeRss(rootPid) {
  const procs = new Map();
  let names;
  try { names = await fs.readdir('/proc'); } catch { return null; }
  await Promise.all(names.filter((n) => /^\d+$/.test(n)).map(async (n) => {
    try {
      const stat = await fs.readFile(`/proc/${n}/stat`, 'utf8');
      const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
      const ppid = Number(rest[1]);
      const rssPages = Number(rest[21]);
      procs.set(Number(n), { ppid, rss: rssPages * 4096 });
    } catch { /* process vanished */ }
  }));
  if (!procs.has(rootPid)) return null;
  let total = 0;
  const stack = [rootPid];
  const seen = new Set();
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    const p = procs.get(pid);
    if (p) total += p.rss;
    for (const [child, info] of procs) if (info.ppid === pid) stack.push(child);
  }
  return total;
}

export async function launchChrome({ launchId, profileDir, config }) {
  const args = [...CHROME_FLAGS, `--user-data-dir=${profileDir}`, '--remote-debugging-pipe', 'about:blank'];
  const browser = await puppeteer.launch({
    executablePath: config.executablePath,
    ignoreDefaultArgs: true,
    args,
    pipe: true,
    handleSIGINT: false,
    handleSIGTERM: false,
    handleSIGHUP: false,
    timeout: 30000,
  });
  const child = browser.process();
  const pid = child ? child.pid : null;
  let exitedResolve;
  const exited = new Promise((resolve) => { exitedResolve = resolve; });
  const engine = {
    id: launchId,
    pid,
    version: await browser.version(),
    exited,
    onDown: null,
    render: (job, opts) => renderJob({ browser, job, config, signal: opts.signal, deadlineAt: opts.deadlineAt }),
    memoryBytes: () => (pid ? processTreeRss(pid) : Promise.resolve(null)),
    async kill() {
      if (pid) {
        try { process.kill(-pid, 'SIGKILL'); } catch { /* group already gone */ }
        try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ }
      }
      await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
    },
    async close() {
      const closed = browser.close().then(() => 'closed', () => 'error');
      const result = await Promise.race([closed, new Promise((r) => setTimeout(() => r('timeout'), config.closeTimeoutMs))]);
      if (result !== 'closed') await engine.kill();
      else await Promise.race([exited, new Promise((r) => setTimeout(r, 2000))]);
    },
  };
  engine.probe = () => browser.version(); // sends Browser.getVersion
  if (child) {
    child.once('exit', () => { exitedResolve(); if (engine.onDown) engine.onDown('process exit'); });
  } else {
    exitedResolve();
  }
  browser.on('disconnected', () => { if (engine.onDown) engine.onDown('disconnected'); });
  return engine;
}
