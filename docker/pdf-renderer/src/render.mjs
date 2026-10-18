// One render job: HTML in, PDF bytes out, through raw CDP on a puppeteer-core page.
// Matches the prototype that reproduced Gotenberg pixel for pixel; every behaviour that
// differs from Gotenberg is an env switch (see config.mjs) so it can be tested alone.

import fs from 'node:fs/promises';
import path from 'node:path';

export const EMPTY_TEMPLATE = '<html><head></head><body></body></html>';
export const MAIN_URL = 'http://render.invalid/index.html';
const PRINT_COLOR_CSS = 'html{-webkit-print-color-adjust:exact !important}';
const NO_BACKGROUND_CSS = 'html,body{background:none !important}';

export class AbortedError extends Error {
  constructor(reason) {
    super(`render aborted: ${reason}`);
    this.name = 'AbortedError';
    this.reason = reason;
  }
}

export class CrashError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CrashError';
    this.crash = true;
  }
}

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve('timeout'), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

export function countPages(buffer) {
  const text = buffer.toString('latin1');
  const matches = text.match(/\/Type\s*\/Page(?![A-Za-z])/g);
  return matches ? matches.length : 0;
}

export function isValidPdf(buffer) {
  if (buffer.length < 16 || buffer.subarray(0, 5).toString('latin1') !== '%PDF-') return false;
  let end = buffer.length;
  while (end > 0 && (buffer[end - 1] === 0x0a || buffer[end - 1] === 0x0d || buffer[end - 1] === 0x20 || buffer[end - 1] === 0x00)) end -= 1;
  return end >= 5 && buffer.subarray(end - 5, end).toString('latin1') === '%%EOF';
}

/**
 * @param {object} args
 * @param {import('puppeteer-core').Browser} args.browser
 * @param {object} args.job   { id, html, header, footer, params }
 * @param {object} args.config
 * @param {AbortSignal} args.signal
 * @param {number} args.deadlineAt  epoch ms
 */
export async function renderJob({ browser, job, config, signal, deadlineAt }) {
  const { html, header, footer, params } = job;
  let context = null;
  let page = null;
  let cdp = null;
  let jobDir = null;
  let onAbort = null;

  const remaining = () => Math.max(1000, deadlineAt - Date.now());

  try {
    if (signal.aborted) throw new AbortedError(String(signal.reason));
    context = config.context === 'perjob' ? await browser.createBrowserContext() : null;
    page = context ? await context.newPage() : await browser.newPage();

    // Anything that ends the page early (deadline, client gone) closes it, which rejects the pending CDP calls.
    onAbort = () => { page.close().catch(() => {}); };
    signal.addEventListener('abort', onAbort, { once: true });
    if (signal.aborted) throw new AbortedError(String(signal.reason));

    const crashed = new Promise((_, reject) => {
      page.once('error', (err) => reject(new CrashError(`page crashed: ${err && err.message}`)));
    });
    crashed.catch(() => {});

    const work = (async () => {
      cdp = await page.createCDPSession();

      if (config.js === 'off') await cdp.send('Emulation.setScriptExecutionDisabled', { value: true });

      let navigateTo = MAIN_URL;
      let mainUrl = MAIN_URL;
      if (config.load === 'file') {
        jobDir = path.join(config.jobsDir, job.id);
        await fs.mkdir(jobDir, { recursive: true });
        await fs.writeFile(path.join(jobDir, 'index.html'), html);
        navigateTo = `file://${jobDir}/index.html`;
        mainUrl = navigateTo;
      }
      const htmlBase64 = Buffer.from(html, 'utf8').toString('base64');

      cdp.on('Fetch.requestPaused', (event) => {
        const url = event.request.url;
        let action;
        if (config.load === 'intercept' && url === mainUrl && !event.responseStatusCode) {
          action = cdp.send('Fetch.fulfillRequest', {
            requestId: event.requestId,
            responseCode: 200,
            responseHeaders: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }],
            body: htmlBase64,
          });
        } else if (config.load === 'file' && url === mainUrl) {
          action = cdp.send('Fetch.continueRequest', { requestId: event.requestId });
        } else if (url.startsWith('data:')) {
          action = cdp.send('Fetch.continueRequest', { requestId: event.requestId });
        } else {
          action = cdp.send('Fetch.failRequest', { requestId: event.requestId, errorReason: 'BlockedByClient' });
        }
        action.catch(() => {});
      });
      await cdp.send('Fetch.enable', { patterns: [{ urlPattern: '*' }] });

      await page.goto(navigateTo, { waitUntil: 'load', timeout: remaining() });

      // Gotenberg's print-colour style, through raw CDP so it works with scripts disabled.
      const css = params.printBackground ? PRINT_COLOR_CSS : `${PRINT_COLOR_CSS}${NO_BACKGROUND_CSS}`;
      const injected = await cdp.send('Runtime.evaluate', {
        expression: `(function(){var s=document.createElement('style');s.appendChild(document.createTextNode(${JSON.stringify(css)}));(document.head||document.documentElement).appendChild(s);return true;})()`,
        returnByValue: true,
      });
      if (injected.exceptionDetails) throw new Error('print style injection failed');

      if (config.fontsReady === 'on') {
        try {
          await withTimeout(
            cdp.send('Runtime.evaluate', { expression: 'document.fonts.ready.then(function(){return true;})', awaitPromise: true, returnByValue: true }),
            config.fontsReadyCapMs,
          );
        } catch (err) {
          if (signal.aborted || (err && err.crash)) throw err;
          // never fatal
        }
      }

      if (params.emulatedMediaType) {
        await cdp.send('Emulation.setEmulatedMedia', { media: params.emulatedMediaType });
      }

      const hasHeaderFooter = header !== undefined || footer !== undefined;
      const printParams = {
        transferMode: 'ReturnAsStream',
        landscape: params.landscape,
        printBackground: params.printBackground,
        scale: params.scale,
        paperWidth: params.paperWidth,
        paperHeight: params.paperHeight,
        marginTop: params.marginTop,
        marginRight: params.marginRight,
        marginBottom: params.marginBottom,
        marginLeft: params.marginLeft,
        preferCSSPageSize: params.preferCssPageSize,
        generateTaggedPDF: false,
        generateDocumentOutline: false,
        displayHeaderFooter: hasHeaderFooter,
      };
      if (hasHeaderFooter) {
        printParams.headerTemplate = header ?? EMPTY_TEMPLATE;
        printParams.footerTemplate = footer ?? EMPTY_TEMPLATE;
      }
      const result = await cdp.send('Page.printToPDF', printParams);
      const chunks = [];
      try {
        for (;;) {
          const chunk = await cdp.send('IO.read', { handle: result.stream, size: 1024 * 1024 });
          chunks.push(Buffer.from(chunk.data, chunk.base64Encoded ? 'base64' : 'utf8'));
          if (chunk.eof) break;
        }
      } finally {
        await cdp.send('IO.close', { handle: result.stream }).catch(() => {});
      }
      return Buffer.concat(chunks);
    })();
    work.catch(() => {});

    let pdf;
    try {
      pdf = await Promise.race([work, crashed]);
    } catch (err) {
      if (signal.aborted && !(err && err.crash)) throw new AbortedError(String(signal.reason));
      throw err;
    }
    return { pdf, pages: countPages(pdf) };
  } finally {
    if (onAbort) signal.removeEventListener('abort', onAbort);
    if (cdp) await withTimeout(cdp.detach().catch(() => {}), 2000);
    if (page) await withTimeout(page.close().catch(() => {}), 3000);
    if (context) await withTimeout(context.close().catch(() => {}), 3000);
    if (jobDir) await fs.rm(jobDir, { recursive: true, force: true }).catch(() => {});
  }
}
