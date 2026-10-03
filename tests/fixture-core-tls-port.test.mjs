import test from 'node:test';
import assert from 'node:assert/strict';
import { coreFixtureTlsPort } from '../scripts/fixture-core-tls-port.mjs';
test('core fixture TLS parser rejects undeclared, malformed and privileged ports',()=>{
 assert.equal(coreFixtureTlsPort(),18443);for(const value of [18443,'18443',19543,'19543'])assert.equal(coreFixtureTlsPort(value),Number(value));
 for(const value of ['',null,443,19544,'019543','19543\n',true,NaN,Infinity])assert.throws(()=>coreFixtureTlsPort(value));
});
