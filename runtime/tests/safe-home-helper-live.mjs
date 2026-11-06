import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, symlinkSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';

// Execute the shipped helper verbatim; no JVM or replacement implementation.
const source = readFileSync(new URL('../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/SafeMode.kt', import.meta.url), 'utf8');
const script = source.match(/const val PLUGINS_SCRIPT = """([\s\S]*?)"""/)[1];
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'safe-home-helper-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const original = join(dir, 'original');
  const rescue = join(dir, 'rescue');
  for (const root of [original, rescue]) mkdirSync(join(root, 'profiles/web'), { recursive: true });
  writeFileSync(join(original, 'profiles/web/package.json'), JSON.stringify({ dsh: { profile: { bundles: ['original-plugin'] } } }));
  writeFileSync(join(rescue, 'profiles/web/package.json'), JSON.stringify({ dsh: { profile: { bundles: ['rescue-plugin'] } } }));
  const helper = join(dir, 'helper.cjs');
  writeFileSync(helper, script);
  const run = (...args) => spawnSync(process.execPath, [helper, ...args], {
    cwd: dir, encoding: 'utf8', env: { ...process.env, DSH_HOME: rescue, DSH_APP_ORIGINAL_HOME: original, DSH_APP_SAFE_DIR: dir },
  });
  return { dir, original, rescue, run, helper };
}

test('safe helper lists the original profile while the engine uses rescue HOME', t => {
  const f = fixture(t);
  const result = f.run('list');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /original-plugin/);
  assert.doesNotMatch(result.stdout, /rescue-plugin/);
});

test('explicit raw export preserves malformed sessions, attachments and workspace data without source writes', t => {
  const f = fixture(t);
  const files = {
    'sessions/project/session.bak-2026/events.jsonl': Buffer.from('not a readable session\n\x00\xff', 'latin1'),
    'attachments/v1/image.bin': Buffer.from([0, 1, 2, 255]),
    'storages/workspace.json': Buffer.from('{broken workspace'),
  };
  for (const [name, bytes] of Object.entries(files)) {
    mkdirSync(join(f.original, name, '..'), { recursive: true });
    writeFileSync(join(f.original, name), bytes);
  }
  writeFileSync(join(f.original, '.credentials.yaml'), 'private-credential');
  mkdirSync(join(f.original, 'logs'));
  writeFileSync(join(f.original, 'logs/private.log'), 'private-token');
  const outside = join(f.dir, 'outside-secret');
  writeFileSync(outside, 'must-not-follow');
  symlinkSync(outside, join(f.original, 'sessions/external-link'));
  const before = Object.fromEntries(Object.keys(files).map(name => [name, statSync(join(f.original, name)).mtimeMs]));
  const target = join(f.dir, 'rescue.tar');
  const result = f.run('export', target);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(statSync(target).mode & 0o777, 0o600);
  const listing = spawnSync('tar', ['-tf', target], { encoding: 'utf8' });
  assert.equal(listing.status, 0, listing.stderr);
  assert.doesNotMatch(listing.stdout, /credentials|private\.log|profiles/);
  for (const [name, bytes] of Object.entries(files)) {
    const extracted = spawnSync('tar', ['-xOf', target, name]);
    assert.equal(extracted.status, 0, String(extracted.stderr));
    assert.deepEqual(extracted.stdout, bytes);
    assert.deepEqual(readFileSync(join(f.original, name)), bytes);
    assert.equal(statSync(join(f.original, name)).mtimeMs, before[name]);
  }
  const linkBytes = spawnSync('tar', ['-xOf', target, 'sessions/external-link']);
  assert.equal(linkBytes.stdout.length, 0, 'archive must not dereference external symlinks');
  assert.doesNotMatch(readFileSync(target).toString('latin1'), /must-not-follow|private-credential|private-token/);
});

test('export requires an explicit new output outside the original HOME, including aliased paths', t => {
  const f = fixture(t);
  mkdirSync(join(f.original, 'sessions'));
  const existing = join(f.dir, 'exists.tar');
  writeFileSync(existing, 'keep');
  const alias = join(f.dir, 'alias');
  symlinkSync(f.original, alias);
  for (const args of [[], [existing], [join(f.original, 'bad.tar')], [join(alias, 'bad.tar')]]) {
    assert.notEqual(f.run('export', ...args).status, 0);
  }
  assert.equal(readFileSync(existing, 'utf8'), 'keep');
  assert.equal(existsSync(join(f.original, 'bad.tar')), false);
});

test('missing or symlinked sessions cannot become a successful empty or external backup', t => {
  const f = fixture(t);
  const target = join(f.dir, 'backup.tar');
  assert.notEqual(f.run('export', target).status, 0);
  assert.equal(existsSync(target), false);
  const other = join(f.dir, 'other-sessions');
  mkdirSync(other);
  symlinkSync(other, join(f.original, 'sessions'));
  assert.notEqual(f.run('export', target).status, 0);
  assert.equal(existsSync(target), false);
});


test('export rejects an intermediate storage symlink instead of reading its external workspace', t => {
  const f = fixture(t);
  mkdirSync(join(f.original, 'sessions'));
  const storage = join(f.dir, 'external-storage');
  mkdirSync(storage);
  writeFileSync(join(storage, 'workspace.json'), 'external-data');
  symlinkSync(storage, join(f.original, 'storages'));
  const target = join(f.dir, 'backup.tar');
  const result = f.run('export', target);
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(target), false);
});

test('real missing tar failure removes the incomplete new archive and preserves the source', t => {
  const f = fixture(t);
  mkdirSync(join(f.original, 'sessions'));
  const original = join(f.original, 'sessions/events.jsonl');
  writeFileSync(original, 'original-bytes');
  const emptyPath = join(f.dir, 'empty-bin');
  mkdirSync(emptyPath);
  const target = join(f.dir, 'failed.tar');
  const result = spawnSync(process.execPath, [f.helper, 'export', target], {
    cwd: f.dir, encoding: 'utf8',
    env: { ...process.env, PATH: emptyPath, DSH_HOME: f.rescue, DSH_APP_ORIGINAL_HOME: f.original },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /tar.*ENOENT/);
  assert.doesNotMatch(result.stdout, /已导出/);
  assert.equal(existsSync(target), false);
  assert.equal(readFileSync(original, 'utf8'), 'original-bytes');
});
