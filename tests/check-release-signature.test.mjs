import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/check-release-signature.sh against a scratch repository with real ssh-keygen keys. The signers are those of the PREVIOUS final tag.
const root = new URL('..', import.meta.url).pathname;
const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid' };
const gitIn = (dir, more = {}) => (...args) => {
  const r = spawnSync('git', ['-C', dir, '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args], { encoding: 'utf8', env: { ...env, ...more } });
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

const have = cmd => spawnSync('bash', ['-c', `command -v ${cmd}`]).status === 0;
// A throwaway OpenPGP key in a scratch GNUPGHOME: the host keyring that must not vouch for a release tag.
const gpgKey = dir => {
  const home = join(dir, 'gnupg'); mkdirSync(home, { mode: 0o700 });
  const r = spawnSync('gpg', ['--batch', '--passphrase', '', '--quick-gen-key', 'release@example.invalid', 'default', 'default', 'never'], { encoding: 'utf8', env: { ...process.env, GNUPGHOME: home } });
  assert.equal(r.status, 0, r.stderr);
  return { home, id: 'release@example.invalid' };
};

test('check-release-signature.sh: a release may not drop the key list; the first signed release is checked against its own list', () => {
  const keys = mkdtempSync(join(tmpdir(), 'warehouse-relsig-keys-'));
  try {
    const good = makeKey(keys, 'good'); const other = makeKey(keys, 'other');
    // M2: the previous release lists a key and the tagged commit lists none.
    const drop = fixture(good.line);
    try {
      drop.commit('# no key any more\n', 'dropped');
      drop.git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${good.file}`, 'tag', '-s', '-m', 'x', 'v1.1.0');
      const r = drop.check('v1.1.0');
      assert.equal(r.status, 1);
      assert.match(r.stderr, /v1\.0\.0 lists a release signing key[^]*v1\.1\.0 lists none/);
    } finally { drop.cleanup(); }
    // L2: the previous release lists none, the tagged commit lists the key.
    const first = fixture('# placeholder\n');
    try {
      first.commit(good.line, 'adds the key'); first.git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${good.file}`, 'tag', '-s', '-m', 'x', 'v1.1.0');
      const r = first.check('v1.1.0');
      assert.equal(r.status, 0, r.stderr);
      assert.match(r.stdout, /::notice title=First signed release::/);
      first.commit(good.line, 'again'); first.git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${other.file}`, 'tag', '-s', '-m', 'x', 'v1.2.0');
      assert.equal(first.check('v1.2.0').status, 1, 'signed by a key the commit does not list');
      first.commit(good.line, 'unsigned'); first.git('tag', '-a', '-m', 'x', 'v1.3.0');
      assert.equal(first.check('v1.3.0').status, 1, 'unsigned');
    } finally { first.cleanup(); }
    // L6: no previous final tag at all (only the tag itself): nothing to check against, with a notice.
    const dir = mkdtempSync(join(tmpdir(), 'warehouse-relsig-'));
    try {
      const git = gitIn(dir);
      git('init', '-q', '-b', 'main'); writeFileSync(join(dir, 'f'), 'x'); git('add', '-A'); git('commit', '-q', '-m', 'one'); git('tag', '-a', '-m', 'x', 'v1.0.0');
      const r = spawnSync('bash', [join(root, 'scripts/check-release-signature.sh'), 'v1.0.0'], { cwd: dir, encoding: 'utf8', env });
      assert.equal(r.status, 0, r.stderr);
      assert.match(r.stdout, /::notice title=Signature not checked::No previous final release tag/);
    } finally { rmSync(dir, { recursive: true, force: true }); }
    // A tag message that carries a PGP signature block as well as the SSH one is refused (M1).
    const both = fixture(good.line);
    try {
      both.commit(undefined, 'both');
      both.git('-c', 'gpg.format=ssh', '-c', `user.signingkey=${good.file}`, 'tag', '-s', '-m', 'x\n-----BEGIN PGP SIGNATURE-----\ny', 'v1.1.0');
      const r = both.check('v1.1.0');
      assert.equal(r.status, 1);
      assert.match(r.stderr, /PGP or X\.509 signature as well as an SSH one/);
    } finally { both.cleanup(); }
  } finally { rmSync(keys, { recursive: true, force: true }); }
});

test('check-release-signature.sh: a tag signed with OpenPGP is refused even when the host keyring holds the key', { skip: !have('gpg') && 'gpg is not installed' }, () => {
  const keys = mkdtempSync(join(tmpdir(), 'warehouse-relsig-keys-'));
  try {
    const good = makeKey(keys, 'good');
    const pgp = gpgKey(keys);
    const f = fixture(good.line);
    try {
      f.commit(undefined, 'pgp');
      gitIn(f.repo, { GNUPGHOME: pgp.home })('-c', 'gpg.format=openpgp', '-c', `user.signingkey=${pgp.id}`, 'tag', '-s', '-m', 'x', 'v1.1.0');
      const r = spawnSync('bash', [join(root, 'scripts/check-release-signature.sh'), 'v1.1.0'], { cwd: f.repo, encoding: 'utf8', env: { ...env, GNUPGHOME: pgp.home } });
      assert.equal(r.status, 1);
      assert.match(r.stderr, /v1\.1\.0 carries no SSH signature/);
    } finally { f.cleanup(); }
  } finally { rmSync(keys, { recursive: true, force: true }); }
});
