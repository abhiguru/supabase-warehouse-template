// Closed fictional account sets; replacement authentication requires independent identity proof.
import assert from 'node:assert/strict';
export function fixturePhones(replacement=false,proof={}) {
 assert.equal(typeof replacement,'boolean');
 if(replacement){assert.equal(proof.primaryAdminPresent,false);assert.equal(proof.replacementAdminPresent,true);return new Set(['919888888891','919888888892','919888888893','919888888894']);}
 return new Set(['919888888871','919888888872','919888888873','919888888874']);
}
