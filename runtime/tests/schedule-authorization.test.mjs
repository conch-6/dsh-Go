// Exercise the actual patched service/tool bodies over memory-only seams.
// DSH_PREFIX=<isolated patched prefix> node --test runtime/tests/schedule-authorization.test.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_PREFIX;
if (!prefix) throw Error('Set DSH_PREFIX to an isolated patched candidate, not a live Host');
const modulePath = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-schedule/lib/index.js');
const source = await readFile(modulePath, 'utf8');
assert.match(source, /dshGoAuthorize\(sessionId, record, "create", signal\)/);
const { ScheduleService, createAfterScheduleRecord } = await import(pathToFileURL(modulePath));
const { apply: applyTools } = await import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-tool-schedule/lib/index.js')));
const approveLabel = '\u6388\u6743 / Authorize';
const signal = () => new AbortController().signal;
const required = error => error.code === 'schedule-authorization-required';
const delay = () => new Promise(resolve => setImmediate(resolve));
const granted = request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel] }] });
const details = request => JSON.parse(request.questions[0].question.split('\n\n').at(-1));
const createRequest = () => ({ title: 'Synthetic task', prompt: 'Harmless synthetic instructions', after_seconds: 86400 });

function fixture({ answer = granted, provider = true, resolveError = false, delegated = false } = {}) {
  const rows = new Map();
  const requests = [];
  const writes = [];
  const controls = [];
  const agent = { id: 'synthetic-session', options: {}, session: { id: 'synthetic-session', header: { delegationDepth: delegated ? 1 : 0 } } };
  let inMutation = false;
  const questions = { async ask(request) {
    assert.equal(inMutation, false, 'human interaction must not hold the mutation/deletion queue');
    assert.equal(request.agent, agent);
    requests.push(request);
    return answer(request);
  } };
  const table = {
    get: id => rows.get(id),
    entries: () => rows.entries(),
    async put(id, value) { rows.set(id, structuredClone(value)); writes.push({ id, value: structuredClone(value) }); },
    async delete(id) { rows.delete(id); },
  };
  const ctx = {
    get: name => name === 'userQuestions' && provider ? questions : undefined,
    agents: new Map([[agent.id, agent]]),
    sessionController: { async resolveAgent(id) {
      assert.equal(id, agent.id);
      controls.push('resolve');
      return resolveError ? { error: Error('Synthetic missing session') } : { agent };
    } },
    sessionPersistence: { dshGoDeletion: {
      assertAdmit() {},
      async withMutation(work) { assert.equal(inMutation, false); inMutation = true; try { return await work(); } finally { inMutation = false; } },
    } },
    approval: { request() { throw Error('Generic approval must not be used'); }, effectivePolicy: () => 'never' },
  };
  const service = Object.create(ScheduleService.prototype);
  Object.defineProperty(service, 'ctx', { value: ctx });
  Object.assign(service, {
    chain: Promise.resolve(), stopping: false, dshGoAuthorizationAbort: new AbortController(),
    getDomain: async () => ({ table(name) { assert.equal(name, 'tasks'); return table; } }),
    emitChanged: () => controls.push('changed'), runtime: { requestDrive: () => controls.push('drive') },
  });
  function seed() {
    const record = createAfterScheduleRecord('synthetic-task', 'Old synthetic instructions', 86400, Date.now(), 'Old name');
    rows.set(record.id, { sessionId: agent.id, record: structuredClone(record), status: 'active', deliveryHistory: { records: [], earlierRecordsUnavailable: false } });
    return record;
  }
  return { service, rows, requests, writes, controls, seed, ctx, agent };
}

function pendingFixture(options = {}) {
  let accept;
  const waiting = new Promise(resolve => { accept = resolve; });
  const f = fixture({ ...options, answer: () => waiting });
  return { ...f, approve: (index = 0) => accept(granted(f.requests[index])), answer: accept };
}

for (const policy of ['ask', 'never', 'auto']) test(`create needs a separate answer even under ${policy}`, async () => {
  const f = pendingFixture();
  f.ctx.approval.effectivePolicy = () => policy;
  const creation = f.service.create(f.agent.id, createRequest(), signal());
  await delay();
  assert.equal(f.requests.length, 1);
  assert.equal(f.writes.length, 0);
  assert.equal(f.requests[0].purpose, 'schedule-authorization');
  assert.equal(f.requests[0].questions[0].multiSelect, false);
  assert.equal(details(f.requests[0]).operation, 'create');
  f.approve();
  const record = await creation;
  assert.equal(f.writes.length, 1);
  assert.deepEqual(record, details(f.requests[0]).task, 'commit exactly the reviewed record and absolute time');
  assert.equal(f.requests[0].signal.aborted, true, 'settling withdraws the request lifetime');
});

for (const [name, answer] of [
  ['legacy automatic approval string', () => 'allowed-once'],
  ['no answer', () => undefined],
  ['empty answers', () => ({ answers: [] })],
  ['explicit rejection', request => ({ answers: [{ id: request.questions[0].id, selected: ['Reject'] }] })],
  ['typed consent', request => ({ answers: [{ id: request.questions[0].id, selected: [], custom: approveLabel }] })],
  ['mixed selection', request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel, 'Reject'] }] })],
  ['selection plus free text', request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel], custom: 'yes' }] })],
  ['wrong pending id', () => ({ answers: [{ id: 'old-pending', selected: [approveLabel] }] })],
  ['missing provider', null],
]) test(`${name} never creates a task`, async () => {
  const f = fixture({ answer: answer ?? granted, provider: answer !== null });
  await assert.rejects(f.service.create(f.agent.id, createRequest(), signal()), required);
  assert.equal(f.writes.length, 0);
});

for (const options of [
  { resolveError: true }, { delegated: true },
  { answer: () => { throw Error('Synthetic disconnected answerer'); } },
]) test(`unavailable routing fails closed: ${JSON.stringify(options)}`, async () => {
  const f = fixture(options);
  await assert.rejects(f.service.create(f.agent.id, createRequest(), signal()), required);
  assert.equal(f.writes.length, 0);
});

test('untrusted formatting cannot hide fields, and changing caller input cannot change the approved task', async () => {
  const f = pendingFixture();
  const input = { ...createRequest(), prompt: 'Visible\u202einjected\u2066text' };
  const creation = f.service.create(f.agent.id, input, signal());
  await delay();
  input.prompt = 'Changed after review';
  const question = f.requests[0].questions[0].question;
  assert.equal(question.includes('\u202e'), false);
  assert.equal(question.includes('\\u202e'), true);
  assert.equal(question.includes('\\u2066'), true);
  f.approve();
  const record = await creation;
  assert.equal(record.prompt, 'Visible\u202einjected\u2066text');
});

for (const timing of [
  { after_seconds: 86400 },
  { at: '2099-12-30T23:00:00Z' },
  { every_seconds: 3600 },
  { daily: { time: '23:00:00', time_zone: 'Asia/Taipei' } },
  { weekly: { time: '23:00:00', time_zone: 'Asia/Taipei', weekdays: [1, 5] } },
  { cron: { expression: '0 23 * * *', time_zone: 'Asia/Taipei' } },
]) test(`review includes normalized timing ${Object.keys(timing)[0]}`, async () => {
  const f = fixture();
  const record = await f.service.create(f.agent.id, { title: 'Synthetic', prompt: 'Harmless', ...timing }, signal());
  const reviewed = details(f.requests[0]);
  assert.equal(reviewed.sessionId, f.agent.id);
  assert.deepEqual(reviewed.task, record);
  assert.equal(Number.isFinite(Date.parse(reviewed.task.scheduledAt)), true);
});

test('direct RPC-shaped update must review the entire merged candidate', async () => {
  const f = pendingFixture();
  const original = f.seed();
  const editing = f.service.update({ id: original.id, sessionId: f.agent.id, expected: original, prompt: 'New synthetic instructions' }, signal());
  await delay();
  assert.equal(f.writes.length, 0);
  const reviewed = details(f.requests[0]);
  assert.equal(reviewed.operation, 'update');
  assert.equal(reviewed.task.title, original.title);
  assert.equal(reviewed.task.scheduledAt, original.scheduledAt);
  assert.equal(reviewed.task.prompt, 'New synthetic instructions');
  f.approve();
  const result = await editing;
  assert.equal(result.updated, true);
  assert.deepEqual(f.rows.get(original.id).record, reviewed.task);
});

test('denied update leaves the original task intact', async () => {
  const f = fixture({ answer: () => ({ answers: [] }) });
  const original = f.seed();
  await assert.rejects(f.service.update({ id: original.id, sessionId: f.agent.id, expected: original, title: 'New name' }, signal()), required);
  assert.deepEqual(f.rows.get(original.id).record, original);
  assert.equal(f.writes.length, 0);
});

for (const change of ['edited', 'deleted', 'ended']) test(`update rechecks state after review: ${change}`, async () => {
  const f = pendingFixture();
  const original = f.seed();
  const editing = f.service.update({ id: original.id, sessionId: f.agent.id, expected: original, prompt: 'New instructions' }, signal());
  await delay();
  if (change === 'deleted') {
    // Real delete must complete while an update's human question is still pending.
    assert.equal((await f.service.delete({ id: original.id, sessionId: f.agent.id }, signal())).deleted, true);
  } else if (change === 'edited') {
    f.rows.get(original.id).record.title = 'Concurrent change';
  } else {
    f.rows.get(original.id).status = 'inactive';
  }
  f.approve();
  const result = await editing;
  assert.equal(result.updated, false);
  assert.equal(result.code, { edited: 'schedule_conflict', deleted: 'schedule_not_found', ended: 'schedule_ended' }[change]);
  assert.equal(f.writes.length, 0);
});

test('no-op and invalid/stale updates never ask or mutate', async () => {
  const f = fixture();
  const original = f.seed();
  const noop = await f.service.update({ id: original.id, sessionId: f.agent.id, expected: original }, signal());
  assert.equal(noop.updated, false);
  const stale = await f.service.update({ id: original.id, sessionId: f.agent.id, expected: { ...original, title: 'Stale' }, prompt: 'New' }, signal());
  assert.equal(stale.code, 'schedule_conflict');
  assert.equal(f.requests.length, 0);
  assert.equal(f.writes.length, 0);
});

for (const cancellation of ['caller', 'service']) test(`pending ${cancellation} cancellation prevents late authorization`, async () => {
  const f = pendingFixture();
  const caller = new AbortController();
  const creation = f.service.create(f.agent.id, createRequest(), caller.signal);
  await delay();
  if (cancellation === 'caller') caller.abort();
  else { f.service.stopping = true; f.service.dshGoAuthorizationAbort.abort(); }
  await assert.rejects(creation, required);
  f.approve();
  await delay();
  assert.equal(f.writes.length, 0);
  assert.equal(f.requests[0].signal.aborted, true);
});

test('unattended authorization times out and a late answer cannot commit', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = pendingFixture();
  const creation = f.service.create(f.agent.id, createRequest(), signal());
  await delay();
  t.mock.timers.tick(120000);
  await assert.rejects(creation, required);
  f.approve();
  await delay();
  assert.equal(f.writes.length, 0);
});

test('expired candidate is not silently re-anchored after confirmation', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2030-01-01T00:00:00Z') });
  const f = pendingFixture();
  const creation = f.service.create(f.agent.id, { ...createRequest(), after_seconds: 2 }, signal());
  await delay();
  t.mock.timers.tick(3000);
  f.approve();
  await assert.rejects(creation, error => required(error) && /time has passed/.test(error.message));
  assert.equal(f.writes.length, 0);
});

test('a previous question answer cannot authorize a later task', async () => {
  let previous;
  const f = fixture({ answer: request => {
    const response = previous ?? granted(request);
    previous = response;
    return response;
  } });
  await f.service.create(f.agent.id, createRequest(), signal());
  await assert.rejects(f.service.create(f.agent.id, createRequest(), signal()), required);
  assert.equal(f.writes.length, 1);
  assert.notEqual(f.requests[0].questions[0].id, f.requests[1].questions[0].id);
});

test('service shutdown after authorization but before queued commit prevents mutation', async () => {
  const f = fixture();
  let release;
  f.service.chain = new Promise(resolve => { release = resolve; });
  const creation = f.service.create(f.agent.id, createRequest(), signal());
  await delay();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].signal.aborted, true, 'human already answered');
  f.service.stopping = true;
  f.service.dshGoAuthorizationAbort.abort();
  release();
  await assert.rejects(creation);
  assert.equal(f.writes.length, 0);
});

test('tool boundary returns the stable authorization error instead of creating silently', async () => {
  const f = fixture({ provider: false });
  const definitions = new Map();
  const ctx = { schedule: f.service, tools: { register(def) { definitions.set(def.name, def); } }, inject(_deps, callback) { callback(this); } };
  applyTools(ctx);
  const result = await definitions.get('schedule_create').execute(createRequest(), { agent: f.agent, signal: signal() });
  assert.equal(result.code, 'authorization_required');
  assert.equal(f.writes.length, 0);
});
