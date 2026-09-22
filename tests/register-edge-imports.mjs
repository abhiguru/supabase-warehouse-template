import { register } from 'node:module';

register('./edge-import-loader.mjs', import.meta.url);
