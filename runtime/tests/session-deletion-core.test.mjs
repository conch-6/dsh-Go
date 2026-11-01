// The bundled deletion seam: durable tombstones, generation cleanup, fences.
// In-memory storage over a throwaway temp directory; no engine, no user data.
//   node --test runtime/tests/session-deletion-core.test.mjs
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';

const { createDeletionSeam } = await import(pathToFileURL(resolve('runtime/session-deletion/core.mjs')));

const leases = new Set();
const acquire = async (dir) => {
  if (leases.has(dir)) throw Object.assign(new Error('owned'), { name: 'SessionAlreadyOwnedError' });
  leases.add(dir);
  return { async release() { leases.delete(dir); } };
};
const parseGeneration = (name) => (/^session(?:\.v[1-9][0-9]*)?\.jsonl(?:\.zstd)?$/.test(name) ? {} : undefined);
const notFound = (id) => Object.assign(new Error(`missing ${id}`), { code: 'not-found' });

let root;
let seam;
let files;
let live;
let header;
let corpus;
let taskRows;
let storedEvents;
let cleanups;

function storage() {
  return {
    root,
    ctx: {
      get: (name) => (name === 'sessions'
        ? { get: (id) => live.get(id), list: () => [...live.values()] }
        : undefined),
      emit: () => {},
    },
    tracker: { claimWrite() {}, releaseClaim() {} },
    coldLogMemo: new Map(),
    migrationPreparations: new Map(),
    async findLog(id) {
      const dir = join(root, 'aa', id);
      return files[id] === undefined ? undefined : { currentPath: join(dir, files[id][0]) };
    },
    async readGenerationHeader() {
      return { header };
    },
    async list() {
      return corpus.map((entry) => ({ header: entry }));
    },

    async requireStoredLog() {
      return { events: storedEvents };
    },
  };
}

const directory = (id) => join(root, 'aa', id);
const hooks = () => ({
  prepare: async () => {},
  inspectTasks: async () => taskRows,
  cleanup: async () => { cleanups++; },
});

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'dsh-del-'));
  leases.clear();
  files = {};
  live = new Map();
  header = { id: 's1' };
  corpus = [];
  taskRows = false;
  storedEvents = [];
  cleanups = 0;
  seam = createDeletionSeam(storage(), { acquire, parseGeneration, notFound });
  await mkdir(join(root, 'aa', 's1'), { recursive: true });
  await writeFile(join(root, 'aa', 's1', 'session.jsonl'), '{}\n');
  files.s1 = ['session.jsonl'];
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

test('removes every stored generation, clears derived state, and leaves a durable tombstone', async () => {
  for (const name of ['session.v2.jsonl', 'session.v3.jsonl.zstd', 'session.v4.jsonl.deadbeef.tmp']) {
    await writeFile(join(directory('s1'), name), 'x');
  }
  files.s1 = ['session.v2.jsonl', 'session.v3.jsonl.zstd', 'session.v4.jsonl.deadbeef.tmp'];
  await seam.delete('s1', hooks());
  assert.deepEqual(await readdir(directory('s1')), []);
  assert.equal(cleanups, 1);
  assert.equal(seam.deleted('s1'), true);
  assert.throws(() => seam.assertAdmit('s1'), (error) => error.code === 'not-found');
  // The tombstone records where the logs were so a retry can finish safely.
  assert.equal(existsSync(join(root, '.dsh-go-lifecycle')), true);
  // A stale id is not admitted into a new materialisation either.
  assert.throws(() => seam.assertParent({ id: 'child', origin: 'subagent', parentSession: 's1' }), (e) => e.code === 'not-found');
});

test('unrelated files beside the logs are left alone', async () => {
  await writeFile(join(directory('s1'), 'notes.md'), 'keep');
  await seam.delete('s1', hooks());
  assert.deepEqual(await readdir(directory('s1')), ['notes.md']);
});

test('a live agent, a related subagent and reminder rows are refused', async () => {
  live.set('s1', { header: { id: 's1' } });
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'writer-held');
  live.clear();

  header = { id: 's1', origin: 'subagent', parentSession: 'p' };
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  header = { id: 's1', delegationDepth: 2 };
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  header = { id: 's1' };
  corpus = [{ id: 'kid', origin: 'subagent', parentSession: 's1' }];
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  corpus = [];
  taskRows = true;
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  assert.equal(seam.deleted('s1'), false);
  assert.equal(cleanups, 0);
});

test('a symlinked session directory is refused instead of deleting elsewhere', async () => {
  const outside = await mkdtemp(join(tmpdir(), 'dsh-outside-'));
  try {
    await writeFile(join(outside, 'session.jsonl'), 'x');
    await rm(directory('s1'), { recursive: true, force: true });
    await symlink(outside, directory('s1'));
    await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'failed');
    assert.equal(existsSync(join(outside, 'session.jsonl')), true);
    assert.equal(seam.deleted('s1'), false);
  } finally {
    await rm(outside, { recursive: true, force: true });
  }
});

test('a failed cleanup still leaves the durable tombstone so a retry completes', async () => {
  await seam.delete('s1', {
    prepare: async () => {},
    inspectTasks: async () => false,
    cleanup: async () => { throw Object.assign(new Error('cache down'), { code: 'failed' }); },
  }).catch((error) => assert.equal(error.code, 'failed'));
  assert.equal(seam.deleted('s1'), true);
  assert.deepEqual(await readdir(directory('s1')), []);
  assert.equal(cleanups, 0);
  await seam.delete('s1', hooks());
  assert.equal(cleanups, 1);
});

test('concurrent deletion of one id cannot run twice, and the fence clears', async () => {
  let release;
  const gate = new Promise((done) => { release = done; });
  const blocked = seam.delete('s1', { prepare: async () => gate, inspectTasks: async () => false, cleanup: async () => {} });
  await new Promise((done) => setImmediate(done));
  assert.equal(seam.pending.has('s1'), true);
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'writer-held');
  release();
  await blocked;
  assert.equal(seam.pending.has('s1'), false);
  assert.equal(seam.deleted('s1'), true);
});

test('a deleted id cannot be recreated, materialised, opened or written', async () => {
  await seam.delete('s1', hooks());
  assert.throws(() => seam.assertAdmit('s1'), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.materialize({ id: 's1' }, async () => 'created'), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.acquireWriter('s1', directory('s1')), (e) => e.code === 'not-found');
  let wrote = false;
  await seam.cacheWrite('s1', async () => { wrote = true; });
  assert.equal(wrote, false);
});

test('writers take both the identity and the directory lease, released together', async () => {
  const lease = await seam.acquireWriter('s1', directory('s1'));
  assert.equal(leases.size, 2);
  await lease.release();
  assert.equal(leases.size, 0);
  // A pre-existing writer on the same directory blocks a second writer.
  const first = await seam.acquireWriter('s1', directory('s1'));
  await assert.rejects(seam.acquireWriter('s1', directory('s1')), (e) => e.name === 'SessionAlreadyOwnedError');
  await first.release();
  assert.equal(leases.size, 0);
});

test('a deletion fence held while another writer owns the directory fails without a tombstone', async () => {
  const lease = await acquire(directory('s1'));
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.name === 'SessionAlreadyOwnedError');
  assert.equal(seam.deleted('s1'), false);
  await lease.release();
  await seam.delete('s1', hooks());
  assert.equal(seam.deleted('s1'), true);
});
