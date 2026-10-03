import { copyFile, mkdir, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';

// Match the two upstream cpy commands without a glob dependency.
const root = process.cwd();
const source = resolve(root, 'src/lib/sql');
const destination = resolve(root, 'dist/lib/sql');
await mkdir(destination, { recursive: true });
for (const file of await readdir(source, { withFileTypes: true })) {
  if (file.isFile() && file.name.endsWith('.sql')) {
    await copyFile(resolve(source, file.name), resolve(destination, file.name));
  }
}
await mkdir(resolve(root, 'dist/server'), { recursive: true });
await copyFile(resolve(root, 'src/server/format-worker.js'), resolve(root, 'dist/server/format-worker.js'));
