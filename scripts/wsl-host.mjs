import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

// WSL2 keeps the whole Linux filesystem in one file, ext4.vhdx, on a Windows drive (normally C:, seen from Ubuntu as /mnt/c).
// Inside Ubuntu "/" has the virtual size of the disk (about 1 TB), so it shows plenty of room while the Windows drive fills up;
// when that drive is full the file cannot grow and PostgreSQL stops with no earlier sign. This is the one place that says
// whether the host is WSL, which drive to watch, and how much free space that drive must keep.
export const MIN_VHDX_DRIVE_FREE_BYTES = 20 * 1024 ** 3;
export const MIN_VHDX_DRIVE_FREE_PERCENT = 10;

// The kernel release of WSL2 contains "microsoft" (for example 5.15.153.1-microsoft-standard-WSL2). `readText` returns the
// text of a file or null/throws when it cannot be read; a host that cannot be read is not WSL.
export function isWsl(readText, procDir = '/proc') {
  try { return /microsoft/i.test(String(readText(join(procDir, 'sys/kernel/osrelease')) ?? '')); } catch { return false; }
}

// The same test for a named kernel-release file (WAREHOUSE_OSRELEASE_FILE, as scripts/backup.sh reads it), so tests need not depend on the host.
export function isWslHost(env, readText, procDir = '/proc') {
  const file = env?.WAREHOUSE_OSRELEASE_FILE;
  if (!file) return isWsl(readText, procDir);
  try { return /microsoft/i.test(String(readText(file) ?? '')); } catch { return false; }
}

// The Windows drive that holds the virtual disk, as Ubuntu sees it: WAREHOUSE_VHDX_DRIVE in the environment, else VHDX_DRIVE in the
// installation's config/compose.env (which reaches the monitoring units, doctor and backup.sh alike), else /mnt/c. The operator sets
// it when the distro was moved to another drive. A value that is not an absolute path is ignored.
export function vhdxDrive(env = process.env, composeEnv = {}) {
  for (const value of [env.WAREHOUSE_VHDX_DRIVE, composeEnv.VHDX_DRIVE]) if (value && value.startsWith('/')) return value;
  return '/mnt/c';
}

// A Windows drive reaches WSL as a 9p, drvfs or virtiofs mount. /mnt/c can also be an empty directory of the Linux filesystem (automount
// switched off), and statfs on it then reports the virtual disk's own space: it must not be taken for the drive. The mount that holds the
// path is the longest mount point that contains it.
export const WINDOWS_MOUNT_TYPES = ['9p', 'drvfs', 'virtiofs'];
const unescapeMount = text => text.replace(/\\([0-7]{3})/g, (_, o) => String.fromCharCode(parseInt(o, 8)));
export function mountTypeOf(path, mountsText) {
  let best = null;
  for (const line of String(mountsText ?? '').split('\n')) {
    const parts = line.split(' ');
    if (parts.length < 3) continue;
    const point = unescapeMount(parts[1]);
    if ((path === point || path.startsWith(point === '/' ? '/' : `${point}/`)) && (best === null || point.length >= best.point.length)) best = { point, type: parts[2] };
  }
  return best?.type ?? null;
}

// Free space of a path through a child process, so that a hung Windows mount costs ten seconds and not the whole checker run.
// Throws on a failure or a timeout. Returns what fs.statfs would: { bavail, bsize, blocks }.
export function statfsWithTimeout(path, timeoutMs = 10000, command = 'stat') {
  const r = spawnSync(command, ['-f', '-c', '%a %S %b', '--', path], { encoding: 'utf8', timeout: timeoutMs });
  if (r.error || r.status !== 0) throw new Error(r.error?.code === 'ETIMEDOUT' ? `timed out after ${timeoutMs / 1000} s` : String(r.stderr || r.error?.message || 'stat -f failed').trim());
  const m = /^(\d+) (\d+) (\d+)$/.exec(r.stdout.trim());
  if (!m) throw new Error('unexpected stat -f output');
  return { bavail: Number(m[1]), bsize: Number(m[2]), blocks: Number(m[3]) };
}

// The free space of the Windows drive: { free, percent }, or throws with the reason (not a Windows mount, unreadable, timed out).
export function driveSpace(drive, { readText, procDir = '/proc', statfs = statfsWithTimeout } = {}) {
  const type = mountTypeOf(drive, readText(join(procDir, 'mounts')));
  if (!WINDOWS_MOUNT_TYPES.includes(type)) throw new Error(`${drive} is not a Windows drive mount (${type ? `filesystem type ${type}` : 'not mounted'})`);
  const s = statfs(drive);
  const free = Number(s.bavail) * Number(s.bsize);
  const percent = 100 * Number(s.bavail) / Number(s.blocks);
  if (!Number.isFinite(free) || !Number.isFinite(percent)) throw new Error('unexpected free-space figures');
  return { free, percent };
}

// Same shape as doctor's freeSpaceVerdict: a new installation needs the floor to begin; a running one only warns (refusing a start
// on a nearly full drive keeps the facility down and frees nothing).
export function wslDriveVerdict(freeBytes, { newInstall = false, drive = '/mnt/c' } = {}) {
  const gib = (freeBytes / 1024 ** 3).toFixed(1);
  const floor = MIN_VHDX_DRIVE_FREE_BYTES / 1024 ** 3;
  const where = `Windows drive that holds the WSL virtual disk (${drive})`;
  if (newInstall && freeBytes < MIN_VHDX_DRIVE_FREE_BYTES) {
    return { error: `At least ${floor} GiB free space is required on the ${where}; ${gib} GiB is free. Free space on that drive (docs/OPERATOR_INSTALL.md, "Windows host (Ubuntu in WSL2)", "Watch the Windows drive").` };
  }
  if (!newInstall && freeBytes < MIN_VHDX_DRIVE_FREE_BYTES) {
    return { warning: `Only ${gib} GiB is free on the ${where} (less than ${floor} GiB): the virtual disk cannot grow and PostgreSQL stops when that drive is full. Free space on it (docs/OPERATOR_INSTALL.md, "Windows host (Ubuntu in WSL2)", "Watch the Windows drive").` };
  }
  return {};
}
