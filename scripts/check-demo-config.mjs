import { readEnv, root } from './doctor-common.mjs';
import { validateDemoEnv } from './doctor.mjs';
validateDemoEnv(readEnv(root + '/docker/.env'));
console.log('Loopback demo configuration validated; no credentials printed.');
