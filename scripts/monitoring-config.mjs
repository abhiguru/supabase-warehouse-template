// Per-installation monitoring files (docs/MONITORING.md, "Several installations on one host").
//
// Several installations can share one host, and each runs its own Prometheus. cAdvisor reports every
// container on the host, so a Prometheus that scraped it unfiltered would hold, and alert on, the
// containers of the other installations. setup.sh therefore renders, from the checkout's templates,
//   <state>/config/monitoring/prometheus.yml                  (mode 0644; read by the prometheus container)
//   <state>/config/monitoring/alertmanager/alertmanager.yml   (mode 0644)
//   <state>/config/monitoring/alertmanager/webhook-url        (mode 0600; the facility's Slack webhook URL, when it has one)
//   <state>/data/alertmanager/                                (mode 0700; Alertmanager's silences and notification log)
// and creates <state>/metrics (mode 0755), the textfile directory node exporter reads read-only and
// the backup scripts write (scripts/backup-metrics.sh). docker/docker-compose.override.yml mounts them.
//
// Prometheus v3.15.0 expands ${VAR} in external labels without a feature flag (verified; the old
// --enable-feature=expand-external-labels is an unknown option there), but the relabel regex below cannot
// use an environment variable, so the whole file is rendered here and nothing is left to expansion.
import { chmodSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

export const PROJECT_PATTERN = /^warehouse-[a-z0-9-]+$/;
export const PLACEHOLDER = '${WAREHOUSE_PROJECT_NAME}';
export const WEBHOOK_MAX_BYTES = 2048;
export const UNSAFE_NAME_CHARACTERS = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;
export const COMPANY_PLACEHOLDER = '${WAREHOUSE_COMPANY}';
// A Slack incoming-webhook URL, and nothing else: the only receiver this repository supports.
export const SLACK_WEBHOOK_PATTERN = /^https:\/\/hooks\.slack\.com\/services\/[A-Z0-9]+\/[A-Z0-9]+\/[A-Za-z0-9]+$/;
// The templates are the ones next to this script, whichever checkout directory a caller names.
export const TEMPLATE_DIR = fileURLToPath(new URL('../docker/', import.meta.url));

export function renderPrometheusConfig(template, project) {
  // The project name is spliced into a YAML scalar and a regular expression: only the characters of a
  // compose project name this repository creates are allowed, none of which is special in either.
  if (!PROJECT_PATTERN.test(project ?? '')) throw new Error('WAREHOUSE_PROJECT_NAME must be warehouse- followed by lower-case letters, digits and hyphens.');
  if (!template.includes(PLACEHOLDER)) throw new Error('docker/prometheus.yml no longer carries the project placeholder.');
  const rendered = template.replaceAll(PLACEHOLDER, project);
  if (rendered.includes('${')) throw new Error('docker/prometheus.yml holds a variable other than the project placeholder.');
  return rendered;
}

// The address in an --alert-webhook-file: one Slack incoming-webhook URL. The file is the operator's
// secret (the address carries a token), so no message here quotes its contents.
export function alertWebhookAddress(text) {
  const value = text.replace(/^\uFEFF/, '').trim();
  if (!SLACK_WEBHOOK_PATTERN.test(value)) throw new Error('--alert-webhook-file must hold one Slack incoming-webhook URL (https://hooks.slack.com/services/...).');
  return value;
}

// Renders docker/alertmanager.slack.yml for one installation. The company name is free text, so it goes
// in as part of a single-quoted YAML scalar, and a "{{" in it is written so that Alertmanager's template engine
// prints it instead of running it.
export function renderSlackConfig(template, project, company) {
  if (!PROJECT_PATTERN.test(project ?? '')) throw new Error('WAREHOUSE_PROJECT_NAME must be warehouse- followed by lower-case letters, digits and hyphens.');
  if (!template.includes(COMPANY_PLACEHOLDER) || !template.includes(PLACEHOLDER)) throw new Error('docker/alertmanager.slack.yml no longer carries the facility placeholders.');
  // Controls, DEL, the C1 range (NEL included) and the line and paragraph separators end a YAML line in a quoted
  // scalar or are not printable: --company refuses them, and a manifest from elsewhere gets spaces.
  const name = String(company ?? '').replace(UNSAFE_NAME_CHARACTERS, ' ').trim() || project;
  // The title is a single-quoted YAML scalar: only ' needs doubling there.
  const quoted = name.replaceAll('{{', '{{ "{{" }}').replaceAll("'", "''");
  const withProject = template.replaceAll(PLACEHOLDER, project);
  const rendered = withProject.replaceAll(COMPANY_PLACEHOLDER, () => quoted);
  if (withProject.replaceAll(COMPANY_PLACEHOLDER, '').includes('${')) throw new Error('docker/alertmanager.slack.yml holds a variable other than the facility placeholders.');
  return rendered;
}

// --alert-webhook-file PATH | off. Returns undefined (leave the state alone), null (remove the stored
// address) or the address. Everything is checked before anything is written.
export function readAlertWebhook(path, checkout) {
  if (path === undefined) return undefined;
  if (path === 'off') return null;
  if (!isAbsolute(path)) throw new Error('--alert-webhook-file must be an absolute path (or off).');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile()) throw new Error('--alert-webhook-file must be a regular file.');
  if (resolve(path).startsWith(checkout + sep) || realpathSync(path).startsWith(checkout + sep)) throw new Error('--alert-webhook-file must be outside the checkout.');
  if (st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('--alert-webhook-file must be owned by this user and mode 0600 (it holds a secret address).');
  if (st.size > WEBHOOK_MAX_BYTES) throw new Error('--alert-webhook-file is larger than 2 KB.');
  return alertWebhookAddress(readFileSync(path, 'utf8'));
}

function privateDirectory(path, mode) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st) { mkdirSync(path, { mode }); chmodSync(path, mode); return; }
  if (!st.isDirectory() || st.uid !== process.getuid()) throw new Error(`${path} must be a directory owned by this user.`);
  if ((st.mode & 0o777) !== mode) chmodSync(path, mode);
}

// Replaces a file through a same-directory temporary, so a reader sees the old or the new content.
// Returns whether anything changed.
function place(path, bytes, mode) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw new Error(`${path} must be a regular file.`);
  if (st && (st.mode & 0o777) === mode && readFileSync(path).equals(bytes)) return false;
  const stage = `${path}.${randomBytes(8).toString('hex')}`;
  writeFileSync(stage, bytes, { mode, flag: 'wx' });
  try { chmodSync(stage, mode); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
  return true;
}

// The company name in the state's manifest (public/instance.json), or '' when there is none.
export function facilityName(state) {
  try { return String(JSON.parse(readFileSync(join(state, 'public/instance.json'), 'utf8')).companyName ?? ''); } catch { return ''; }
}

// Writes the monitoring files into `state` (an installed state, or the staging directory of a fresh
// one). `webhook` is what readAlertWebhook returned: undefined keeps the stored address, null removes
// it, a string stores it. Returns whether any file changed.
export function placeMonitoringConfig(state, { project, webhook, templates = TEMPLATE_DIR }) {
  const template = readFileSync(join(templates, 'prometheus.yml'), 'utf8');
  const prometheus = renderPrometheusConfig(template, project);
  const stored = join(state, 'config/monitoring/alertmanager/webhook-url');
  const storedAddress = lstatSync(stored, { throwIfNoEntry: false });
  const wanted = webhook === undefined ? Boolean(storedAddress) : webhook !== null;
  const alertmanager = wanted
    ? Buffer.from(renderSlackConfig(readFileSync(join(templates, 'alertmanager.slack.yml'), 'utf8'), project, facilityName(state)))
    : readFileSync(join(templates, 'alertmanager.yml'));

  privateDirectory(join(state, 'config/monitoring'), 0o700);
  privateDirectory(join(state, 'config/monitoring/alertmanager'), 0o700);
  privateDirectory(join(state, 'metrics'), 0o755);
  // Alertmanager runs as the installing user and keeps its state here, so a replaced container keeps its silences.
  privateDirectory(join(state, 'data/alertmanager'), 0o700);
  let changed = false;
  if (typeof webhook === 'string') changed = place(stored, Buffer.from(`${webhook}\n`), 0o600) || changed;
  if (webhook === null && storedAddress) { rmSync(stored); changed = true; }
  changed = place(join(state, 'config/monitoring/prometheus.yml'), Buffer.from(prometheus), 0o644) || changed;
  changed = place(join(state, 'config/monitoring/alertmanager/alertmanager.yml'), alertmanager, 0o644) || changed;
  return changed;
}

// Whether Alertmanager has a receiver outside this host (doctor: "no Slack webhook").
export function alertWebhookConfigured(state) {
  return Boolean(lstatSync(join(state, 'config/monitoring/alertmanager/webhook-url'), { throwIfNoEntry: false })?.isFile());
}

// `running`: whether an alertmanager container is running (compose ps without -a; doctor asks Compose).
export function alertDeliveryWarning(state, running = true) {
  if (alertWebhookConfigured(state)) {
    return running ? null : 'Slack webhook stored but monitoring is not running: no alert will reach Slack and the daily "Monitoring is alive" message has stopped. Start it with `bash start.sh` (or `bash scripts/start-monitoring.sh` while the core services are up); see docs/MONITORING.md.';
  }
  if (!running) return 'No Slack webhook: alerts are not delivered. Monitoring is not running, so this facility raises and sends no alerts at all: nobody is told when a backup fails or the database stops. That is acceptable only for a test install. For a real facility, rerun setup.sh --operator with your usual inputs, leaving out --alert-webhook-file off (it then asks for the URL on a terminal), or pass --alert-webhook-file <a private file holding the URL> (docs/MONITORING.md, "Alert delivery").';
  return 'No Slack webhook: alerts are not delivered. Alertmanager is running with no receiver, so no alert leaves this host and nobody is told when a backup fails or the database stops. Give it the facility\'s Slack incoming-webhook URL: rerun setup.sh --operator with your usual inputs, leaving out --alert-webhook-file off (it then asks for the URL on a terminal), or pass --alert-webhook-file <a private file holding the URL> (docs/MONITORING.md, "Alert delivery").';
}

// node scripts/monitoring-config.mjs STATE PROJECT: renders the files into an installed state without
// touching anything else of it (scripts/restore-host.sh, which never runs setup). The stored webhook
// address, if there is one, is kept.
if (isMain(import.meta.url)) {
  try {
    const [state, project] = process.argv.slice(2);
    if (!state || !isAbsolute(state) || !project || process.argv.length !== 4) throw new Error('Usage: monitoring-config.mjs ABSOLUTE_STATE_DIR PROJECT');
    placeMonitoringConfig(state, { project, webhook: undefined });
  } catch (error) { console.error(`Monitoring configuration: ${error.message}`); process.exitCode = 1; }
}
