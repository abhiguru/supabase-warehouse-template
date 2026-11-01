import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/check-release-signature.sh against a scratch repository with real ssh-keygen keys. The signers are those of the PREVIOUS final tag.
const root = new URL('..', import.meta.url).pathname;
const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid' };
const gitIn = dir => (...args) => {
  const r = spawnSync('git', ['-C', dir, '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args], { encoding: 'utf8', env });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};
const makeKey = (dir, name) => {
  const file = join(dir, name);
  assert.equal(spawnSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', name, '-f', file]).status, 0);
  return { file, line: `release namespaces="git" ${readFileSync(`${file}.pub`, 'utf8').trim()}\n` };
};

function fixture(previousAllowed) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-relsig-'));
  const repo = join(dir, 'repo');
  mkdirSync(repo);
  const git = gitIn(repo);
  git('init', '-q', '-b', 'main');
  const commit = (allowed, msg) => {
    if (allowed !== undefined) { mkdirSync(join(repo, '.github'), { recursive: true }); writeFileSync(join(repo, '.github/allowed_signers'), allowed); }
    writeFileSync(join(repo, 'f'), msg); git('add', '-A'); git('commit', '-q', '-m', msg);
  };
  commit(previousAllowed, 'previous');
  git('tag', '-a', '-m', 'previous', 'v1.0.0');
  const sign = (name, key) => { commit(undefined, name); git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${key.file}`, 'tag', '-s', '-m', name, name); };
  const check = tag => spawnSync('bash', [join(root, 'scripts/check-release-signature.sh'), tag], { cwd: repo, encoding: 'utf8', env });
  return { dir, repo, git, commit, sign, check, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('check-release-signature.sh: the previous release\'s key list decides', () => {
  const keys = mkdtempSync(join(tmpdir(), 'warehouse-relsig-keys-'));
  try {
    const good = makeKey(keys, 'good'); const other = makeKey(keys, 'other');
    const f = fixture(good.line);
    try {
      f.sign('v1.1.0', good);
      assert.equal(f.check('v1.1.0').status, 0, 'signed by a listed key');
      f.sign('v1.2.0', other);
      const wrong = f.check('v1.2.0');
      assert.equal(wrong.status, 1);
      assert.match(wrong.stderr, /::error title=Release tag is not signed by a trusted key::v1\.2\.0 is not signed by a key listed/);
      f.commit(undefined, 'unsigned'); f.git('tag', '-a', '-m', 'unsigned', 'v1.3.0');
      assert.equal(f.check('v1.3.0').status, 1, 'an unsigned tag');
      // The tagged commit's own list adds the attacker's key; the previous release's list still decides.
      f.commit(good.line + other.line, 'own list'); f.git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${other.file}`, 'tag', '-s', '-m', 'x', 'v1.4.0');
      assert.equal(f.check('v1.4.0').status, 1, 'a key added only by the release itself');
    } finally { f.cleanup(); }

    // The previous release lists no key (no file, or only comments): nothing to check against, with a notice.
    for (const prev of [undefined, '# placeholder\n']) {
      const g = fixture(prev);
      try {
        g.commit(undefined, 'next'); g.git('tag', '-a', '-m', 'next', 'v1.1.0');
        const r = g.check('v1.1.0');
        assert.equal(r.status, 0, r.stderr);
        assert.match(r.stdout, /::notice title=Signature not checked::v1\.0\.0 lists no release signing key/);
      } finally { g.cleanup(); }
    }
  } finally { rmSync(keys, { recursive: true, force: true }); }
});
