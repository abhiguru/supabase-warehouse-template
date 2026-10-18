// One JSON line per event. Callers pass counters and ids only, never HTML or document data.

const MAX_STRING = 300;

function clean(value) {
  if (typeof value === 'string') return value.length > MAX_STRING ? `${value.slice(0, MAX_STRING)}...` : value;
  return value;
}

export function createLogger(write = (line) => process.stdout.write(`${line}\n`)) {
  return function log(event, fields = {}) {
    const entry = { ts: new Date().toISOString(), event };
    for (const [key, value] of Object.entries(fields)) entry[key] = clean(value);
    write(JSON.stringify(entry));
  };
}

// Error text can echo page content in rare cases, so keep only a short single line.
export function safeMessage(err) {
  const text = String(err && err.message ? err.message : err).split('\n')[0];
  return text.length > 160 ? `${text.slice(0, 160)}...` : text;
}
