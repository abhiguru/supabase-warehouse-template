import { readFileSync } from 'node:fs';
const contents = readFileSync(new URL('../docker/.env',import.meta.url),'utf8');
const value = key => contents.match(new RegExp(`^${key}=([^#\\r\\n]*)`,'m'))?.[1].trim();
if (value('AUTH_MODE') !== 'demo' || value('APP_ENV') !== 'development' || value('BIND_ADDRESS') !== '127.0.0.1') {
  throw new Error('Local demo requires AUTH_MODE=demo, APP_ENV=development, and BIND_ADDRESS=127.0.0.1. Existing .env was not changed.');
}
console.log('Local-only demo configuration validated; no credentials printed.');
