import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CATALOG, HARD_LIMITS } from '../src/config.js';
import { admitGeneration } from '../src/budget.js';
import { createBudgetLedger } from '../src/budget-ledger.js';
import { generateMedia } from '../src/media-engine.js';
import { MediaError } from '../src/errors.js';

const brokenLedger = '{"incomplete":';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'media-release-cleanup-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const workspace = join(directory, 'workspace');
  await mkdir(workspace);
  const request = {
    prompt: 'synthetic circle', n: 1, refs: [],
    service: { id: 'probe', provider: 'openai', profile: 'openai-gpt-image', baseUrl: 'https://api.openai.com/v1' },
    model: CATALOG.models.find(row => row.profile === 'openai-gpt-image' && !row.editOnly),
  };
  let creates = 0;
  const context = {
    hostStateDir: join(directory, 'host-state'), sessionId: 'session-1', keyRef: 'TEST_MEDIA_KEY',
    signal: new AbortController().signal, limits: { ...HARD_LIMITS },
    budget: { dailyMicros: 20_000_000, unknownHoldMicros: 20_000_000 },
    approve: async () => 'allowed-once',
    authorizeWorkspace: async () => ({ cwd: workspace, workspaceRoot: workspace, mode: 'workspace-write' }),
    resolveCredential: async () => 'synthetic-not-a-real-key',
    client: { async create() { creates++; throw new MediaError('provider'); } },
  };
  context.admission = await admitGeneration(request, context);
  const dateDirectory = join(workspace, 'generated', context.admission.outputDate);
  const ledgerPath = join(context.hostStateDir, 'budget', 'ledger-v1.json');
  return {
    context, request, workspace, dateDirectory, ledgerPath,
    get creates() { return creates; },
    async preparedStage() {
      const names = await readdir(dateDirectory);
      assert.equal(names.length, 1, 'real storage preparation must already own one staging directory');
      assert.ok(names[0].startsWith('.' + context.admission.rid + '-'));
      assert.ok(names[0].endsWith('.pending'));
      return join(dateDirectory, names[0]);
    },
    async ledger() { return createBudgetLedger(join(context.hostStateDir, 'budget')).snapshot(); },
  };
}

test('real budget release failure still removes the prepared staging directory', async t => {
  const f = await fixture(t);
  let stage;
  f.context.resolveCredential = async () => {
    stage = await f.preparedStage();
    await writeFile(f.ledgerPath, brokenLedger);
    return '';
  };
  await assert.rejects(generateMedia(f.request, f.context), { code: 'budget' });
  assert.ok(stage);
  assert.deepEqual(await readdir(f.dateDirectory), []);
  assert.equal(await readFile(f.ledgerPath, 'utf8'), brokenLedger, 'cleanup does not repair or refund the broken ledger');
  assert.equal(f.creates, 0);
});

test('unremovable unowned contents still surface cleanup_failed when budget release also fails', async t => {
  const f = await fixture(t);
  let foreign;
  f.context.resolveCredential = async () => {
    const stage = await f.preparedStage();
    foreign = join(stage, 'untracked.txt');
    await writeFile(foreign, 'unowned synthetic bytes');
    await writeFile(f.ledgerPath, brokenLedger);
    return '';
  };
  await assert.rejects(generateMedia(f.request, f.context), { code: 'cleanup_failed' });
  assert.equal(await readFile(foreign, 'utf8'), 'unowned synthetic bytes');
  assert.equal(await readFile(f.ledgerPath, 'utf8'), brokenLedger);
  assert.equal(f.creates, 0);
});

test('successful unsent release retains the original error and clears the stage', async t => {
  const f = await fixture(t);
  f.context.resolveCredential = async () => {
    await f.preparedStage();
    return '';
  };
  await assert.rejects(generateMedia(f.request, f.context), { code: 'credential' });
  assert.deepEqual(await readdir(f.dateDirectory), []);
  assert.equal((await f.ledger()).requests[0].state, 'released');
  assert.equal(f.creates, 0);
});

test('a submitted failure keeps its hold and never attempts an unsent release', async t => {
  const f = await fixture(t);
  let releases = 0;
  const release = f.context.admission.releaseUnsent;
  f.context.admission.releaseUnsent = async () => { releases++; return release(); };
  await assert.rejects(generateMedia(f.request, f.context), { code: 'provider' });
  assert.equal(f.creates, 1);
  assert.equal(releases, 0);
  assert.equal((await f.ledger()).requests[0].state, 'submission_unknown');
  assert.deepEqual(await readdir(f.dateDirectory), []);
});

test('a failed prepare with no store still retains a real release error', async t => {
  const f = await fixture(t);
  await writeFile(f.ledgerPath, brokenLedger);
  f.context.authorizeWorkspace = async () => { throw new MediaError('permission'); };
  await assert.rejects(generateMedia(f.request, f.context), { code: 'budget' });
  await assert.rejects(access(join(f.workspace, 'generated')), { code: 'ENOENT' });
  assert.equal(f.creates, 0);
});
