// The optional letterhead image of the GRN, dispatch, invoice and customer stock PDFs (setup.sh --letterhead-file).
// setup copies the image to <state>/public/letterhead.jpg or letterhead.png and records its name in compose.env
// (LETTERHEAD_FILE); the functions router reads it from the read-only public directory. The rules here are the ones
// setup, doctor and watch share; functions/_shared/letterhead.ts applies the same limits when it reads the file.
//
//   node letterhead.mjs gate --state-dir STATE --company NAME --given VALUE --out FILE
//       decides where the choice comes from (setup.sh runs this after the Slack webhook question, once the lock is held).
//       VALUE is the --letterhead-file argument, or empty. A path or `off` is used as given and nothing is asked.
//       Empty on a fresh state (no config/compose.env), or `ask`, on a terminal: asks for the path of the image (checked;
//       3 tries; Enter means plain PDFs) and writes the answer (a path or `off`) to FILE. Empty on a rerun: keeps what is
//       there and asks nothing. No terminal where it must ask: refuses, exit 1.
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { MAX_ATTEMPTS, readLine } from './alert-webhook.mjs';
import { isMain } from './is-main.mjs';

export const LETTERHEAD_MAX_BYTES = 2 * 1024 * 1024;
export const LETTERHEAD_NAMES = { jpg: 'letterhead.jpg', png: 'letterhead.png' };
export const LETTERHEAD_NAME_PATTERN = /^letterhead\.(?:jpg|png)$/;

const JPEG = [0xff, 0xd8, 0xff];
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const startsWith = (bytes, signature) => bytes.length >= signature.length && signature.every((byte, index) => bytes[index] === byte);

// 'jpg' or 'png' from the first bytes of a file, else null. Only the signature is read: the renderer decodes the image.
export function letterheadKind(bytes) {
  if (startsWith(bytes, JPEG)) return 'jpg';
  if (startsWith(bytes, PNG)) return 'png';
  return null;
}

// The image of --letterhead-file PATH (not `off`), checked before anything is written: returns the file name to store
// (letterhead.jpg or letterhead.png, by the file's first bytes) and the bytes, or throws with the reason.
export function readLetterhead(path) {
  if (!isAbsolute(path)) throw new Error('--letterhead-file must be an absolute path (or off).');
  const st = statSync(path, { throwIfNoEntry: false });
  if (!st?.isFile()) throw new Error('--letterhead-file must be a readable regular file.');
  if (st.size > LETTERHEAD_MAX_BYTES) throw new Error('--letterhead-file is larger than 2 MiB. Save the image at the page width (2480 pixels for A4 at 300 dpi) as a JPEG, or as a smaller PNG.');
  const bytes = readFileSync(path);
  if (bytes.length > LETTERHEAD_MAX_BYTES) throw new Error('--letterhead-file is larger than 2 MiB. Save the image at the page width (2480 pixels for A4 at 300 dpi) as a JPEG, or as a smaller PNG.');
  const kind = letterheadKind(bytes);
  if (!kind) throw new Error('--letterhead-file is not a JPEG or PNG image (its first bytes are not a JPEG or PNG signature); nothing was copied.');
  return { name: LETTERHEAD_NAMES[kind], bytes };
}

export const PROMPT = company => `PDF letterhead for ${company}: the GRN, dispatch, invoice and customer stock PDFs can print your letterhead at the top. Path of a JPEG or PNG image (at most 2 MiB), or press Enter for plain PDFs:`;
export const REFUSAL = 'Refusing: choose the PDF letterhead. Give --letterhead-file /absolute/path/letterhead.png (a JPEG or PNG of at most 2 MiB) to print your letterhead at the top of the GRN, dispatch, invoice and customer stock PDFs, or --letterhead-file off for plain PDFs. Nothing was changed.';
export const ASK_REFUSAL = '--letterhead-file ask needs a terminal to type the path into. Nothing was changed.';
export const OFF_NOTICE = 'No letterhead: the PDFs stay plain. To add one later, rerun setup.sh --operator with your usual inputs plus --letterhead-file /absolute/path/letterhead.png.';

// Reads the path of the image and proves it before it is kept. `ask(promptText)` returns the typed line, or null at end
// of input; `write(text)` prints. Enter means plain PDFs ('off'). A file that cannot be used is explained and asked
// again, within the tries. Returns 'off' or the path, or throws after the last miss (or when the input ends).
export async function obtainLetterhead({ company, ask, write, attempts = MAX_ATTEMPTS }) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const answer = await ask(PROMPT(company));
    if (answer === null) throw new Error('No answer was given; nothing was changed.');
    const value = String(answer).trim();
    if (value === '' || value === 'off') return 'off';
    try { readLetterhead(value); return value; } catch (error) { write(`${error.message}${attempt < attempts ? ' Try again.' : ''}\n`); }
  }
  throw new Error(`No usable letterhead image after ${attempts} tries; nothing was changed.`);
}

// What to do about the letterhead: 'given' (a path or `off` was given), 'prompt' (ask on the terminal: nothing given on
// a fresh state, or `ask`), 'keep' (a rerun with nothing given keeps what is there) or 'refuse' (it needs a terminal
// and there is none).
export function decideLetterheadSource({ given, fresh, isTTY }) {
  if (given === 'ask') return isTTY ? 'prompt' : 'refuse';
  if (given) return 'given';
  if (!fresh) return 'keep';
  return isTTY ? 'prompt' : 'refuse';
}

function option(args, name) {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
}

if (isMain(import.meta.url)) {
  const [command, ...args] = process.argv.slice(2);
  const write = text => process.stderr.write(text);
  try {
    if (command === 'gate') {
      const state = option(args, '--state-dir');
      const out = option(args, '--out');
      if (!state || !out) throw new Error('Usage: letterhead.mjs gate --state-dir STATE --company NAME --given VALUE --out FILE');
      const given = option(args, '--given');
      const decision = decideLetterheadSource({ given, fresh: !existsSync(join(state, 'config/compose.env')), isTTY: Boolean(process.stdin.isTTY) });
      if (decision === 'refuse') { write(`${given === 'ask' ? ASK_REFUSAL : REFUSAL}\n`); process.exitCode = 1; }
      else if (decision === 'prompt') {
        const value = await obtainLetterhead({ company: option(args, '--company') || 'this facility', ask: readLine, write });
        writeFileSync(out, `${value}\n`);
        write(value === 'off' ? `${OFF_NOTICE}\n` : 'Letterhead image accepted; setup copies it into the state (public/letterhead.jpg or letterhead.png).\n');
      }
    } else throw new Error('Usage: letterhead.mjs gate ...');
  } catch (error) { console.error(`Letterhead: ${error.message}`); process.exitCode = 1; }
}
