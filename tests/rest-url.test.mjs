import { test } from 'node:test';
import assert from 'node:assert/strict';
import { restBaseUrl, withoutSlash } from '../functions/_shared/rest-url.ts';

test('restBaseUrl: the direct address when set, else the gateway path; trailing slashes dropped', () => {
  assert.equal(restBaseUrl('http://gateway:8000', undefined), 'http://gateway:8000/rest/v1');
  assert.equal(restBaseUrl('http://gateway:8000/', ''), 'http://gateway:8000/rest/v1');
  assert.equal(restBaseUrl('http://gateway:8000', 'http://rest:3000'), 'http://rest:3000');
  assert.equal(restBaseUrl('http://gateway:8000', 'http://rest:3000//'), 'http://rest:3000');
  assert.equal(withoutSlash(undefined), '');
});
