// Bundled JSONL-only lifecycle seam. Locks and tombstones live beside the log root,
// never in cwd. Lock inodes and tombstones are permanent; IDs cannot be reused.
import { AsyncLocalStorage } from 'node:async_hooks';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { link, lstat, mkdir, open, readdir, realpath, rm } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const failure = (code, message = code) => Object.assign(new Error(message), { code });
const key = (id) => createHash('sha256').update(id).digest('hex');

export function createDeletionSeam(storage, { acquire, parseGeneration, notFound }) {
  const root = resolve(storage.root);
  const control = join(root, '.dsh-go-lifecycle');
  const pending = new Set();
  const context = new AsyncLocalStorage();
  const slot = (id) => join(control, key(id));
  const marker = (id) => join(slot(id), 'deleted.json');
  const deleted = (id) => {
    try { statSync(marker(id)); return true; }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  };
  const assertAdmit = (id) => {
    if (pending.has(id) || deleted(id)) throw notFound(id);
  };
  const assertParent = (header) => {
    if (header.origin === 'subagent' && header.parentSession !== undefined) assertAdmit(header.parentSession);
  };
  const mutation = async (operation) => {
    const inherited = context.getStore();
    if (inherited?.active) {
      const child = Promise.resolve().then(operation);
      inherited.children.add(child);
      child.then(() => inherited.children.delete(child), () => inherited.children.delete(child));
      return child;
    }
    let lock;
    for (let attempt = 0; ; attempt++) {
      try { lock = await acquire(join(control, '_mutations'), 'dsh-go-mutations'); break; }
      catch (error) {
        if (error?.name !== 'SessionAlreadyOwnedError' || attempt >= 500) throw error;
        await delay(20);
      }
    }
    const token = { active: true, children: new Set() };
    try {
      return await context.run(token, async () => {
        try { return await operation(); }
        finally { while (token.children.size) await Promise.allSettled([...token.children]); }
      });
    } finally { token.active = false; await lock.release(); }
  };
  const syncDir = async (path) => {
    const handle = await open(path, 'r');
    try { await handle.sync(); } finally { await handle.close(); }
  };
  const writeMarker = async (id, dir) => {
    await mkdir(slot(id), { recursive: true, mode: 0o700 });
    const temporary = join(slot(id), `.${randomUUID()}.tmp`);
    try {
      const handle = await open(temporary, 'wx', 0o600);
      try {
        await handle.writeFile(JSON.stringify({ version: 1, directory: relative(root, dir) }));
        await handle.sync();
      } finally { await handle.close(); }
      await link(temporary, marker(id));
    } finally { await rm(temporary, { force: true }); }
    await syncDir(slot(id));
    await syncDir(control);
    await syncDir(root);
    await syncDir(dirname(root));
  };
  const savedDirectory = (id) => {
    const record = JSON.parse(readFileSync(marker(id), 'utf8'));
    const rel = record.directory;
    if (record.version !== 1 || typeof rel !== 'string' || isAbsolute(rel)
      || rel.split(/[\\/]/).includes('..') || rel.split(/[\\/]/).length !== 2) throw failure('failed');
    return resolve(root, rel);
  };
  const safeDirectory = async (dir) => {
    // A configured root may itself be a symlink; child/project symlinks are not admitted.
    const canonicalRoot = await realpath(root);
    if (await realpath(dir) !== join(canonicalRoot, relative(root, dir))) throw failure('failed', 'Symlink session directory.');
  };
  const logFiles = async (dir) => {
    const files = [];
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const generation = parseGeneration(entry.name, 'none') !== undefined || parseGeneration(entry.name, 'zstd') !== undefined;
      const temporary = /^session(?:\.v[1-9][0-9]*)?\.jsonl(?:\.zstd)?\.[a-f0-9]+\.tmp$/.test(entry.name);
      if (!generation && !temporary) continue;
      const path = join(dir, entry.name);
      if (!(await lstat(path)).isFile()) throw failure('failed', 'Unexpected log artifact type.');
      files.push(path);
    }
    return files;
  };
  return {
    version: 1, pending, deleted, assertAdmit, assertParent, withMutation: mutation,
    // Global identity lease closes the alternate-cwd create race; the original directory
    // lease also excludes older runtime writers. Neither inode is ever unlinked.
    async acquireWriter(id, dir) {
      assertAdmit(id);
      const identity = await acquire(slot(id), id);
      let artifact;
      try {
        assertAdmit(id);
        artifact = await acquire(dir, id);
        assertAdmit(id);
        return { async release() { try { await artifact.release(); } finally { await identity.release(); } } };
      } catch (error) {
        try { await artifact?.release(); } finally { await identity.release(); }
        throw error;
      }
    },
    async cacheWrite(id, operation) {
      return mutation(async () => { if (!deleted(id)) return operation(); });
    },
    async materialize(header, operation) {
      return mutation(async () => { assertAdmit(header.id); assertParent(header); return operation(); });
    },
    async delete(id, hooks) {
      if (pending.has(id)) throw failure('writer-held');
      pending.add(id); // Synchronous fence precedes the first await and every prompt admission.
      let identity;
      let artifact;
      let claimed = false;
      try {
        const retry = deleted(id);
        if (!retry) {
          const live = storage.ctx.get('sessions')?.list() ?? [];
          const corpus = [...await storage.list(), ...live.map((session) => ({ header: session.header }))];
          if (corpus.some(({ header }) => header.id === id && (header.origin === 'subagent' || (header.delegationDepth ?? 0) > 0)
            || header.origin === 'subagent' && header.parentSession === id)) throw failure('session-related');
          await hooks.prepare();
        }
        if (storage.ctx.get('sessions')?.get(id) !== undefined) throw failure('writer-held');
        storage.tracker.claimWrite(id);
        claimed = true;
        identity = await acquire(slot(id), id);
        let dir;
        if (retry) dir = savedDirectory(id);
        else {
          const selected = await storage.findLog(id);
          if (selected === undefined) throw failure('not-found');
          dir = dirname(selected.currentPath);
        }
        await safeDirectory(dir);
        artifact = await acquire(dir, id);
        await mutation(async () => {
          if (!retry) {
            // Re-read under both leases and the shared mutation fence. Migration reads are
            // observation-only; no old generation is ever resumed or published by delete.
            const metadata = await storage.readGenerationHeader(await storage.findLog(id), id);
            if (metadata === undefined) throw failure('failed');
            if (metadata.header.origin === 'subagent' || (metadata.header.delegationDepth ?? 0) > 0) throw failure('session-related');
            const corpus = await storage.list();
            if (corpus.some(({ header }) => header.origin === 'subagent' && header.parentSession === id)) throw failure('session-related');
            if (await hooks.inspectTasks()) throw failure('session-related');
            const stored = await storage.requireStoredLog(id);
            if (stored.events.some((event) => event.type === 'team/task' || event.type === 'subagent/catalog')) throw failure('session-related');
            const goal = stored.events.filter((event) => event.type === 'goal/change').at(-1)?.data?.goal;
            if (goal?.phase === 'active') throw failure('session-active');
          }
          const files = await logFiles(dir);
          if (!retry) await writeMarker(id, dir); // Durable point of no return; retry completes cleanup.
          storage.coldLogMemo.delete(id);
          storage.migrationPreparations.get(id)?.controller.abort();
          storage.migrationPreparations.delete(id);
          for (const path of files) await rm(path, { force: true });
          await syncDir(dir);
          await hooks.cleanup();
          storage.ctx.emit('dsh-go/session-deleted', id);
        });
      } finally {
        try { await artifact?.release(); }
        finally {
          try { await identity?.release(); }
          finally { if (claimed) storage.tracker.releaseClaim(id); pending.delete(id); }
        }
      }
    },
  };
}
