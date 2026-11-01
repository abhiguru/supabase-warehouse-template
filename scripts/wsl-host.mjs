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

// The Windows drive that holds the virtual disk, as Ubuntu sees it. The operator overrides it when the distro was moved to another drive.
export const vhdxDrive = (env = process.env) => env.WAREHOUSE_VHDX_DRIVE || '/mnt/c';

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
