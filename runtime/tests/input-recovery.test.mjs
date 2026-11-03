// Exact classes extracted from the PATCHED candidate; no user sessions or live Host.
// INPUT_RECOVERY_MODULE=/tmp/.../candidate/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js \
// INPUT_RECOVERY_DEPS_PREFIX=/opt/dsh node --test runtime/tests/input-recovery.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { appendFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { resolve, join, isAbsolute, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_PREFIX;
const modulePath = process.env.INPUT_RECOVERY_MODULE
  ?? (prefix && join(prefix, 'node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js'));
if (!modulePath) throw Error('Set INPUT_RECOVERY_MODULE or DSH_PREFIX to the patched candidate');
const source = readFileSync(modulePath, 'utf8');
assert.match(source, /settledIds: messageIds/, 'tests require the applied recovery patch');
const deps = process.env.INPUT_RECOVERY_DEPS_PREFIX ?? prefix;
if (!deps) throw Error('Set INPUT_RECOVERY_DEPS_PREFIX to an isolated or installed dependency tree');
const require = createRequire(resolve(deps, 'package.json'));
const { z } = require('zod');
const sessionApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session/lib/index.js')));

function region(name) {
  const start = source.indexOf(`//#region lib/types/${name}.js`);
  const end = source.indexOf('//#endregion', start);
  assert(start >= 0 && end > start, `candidate region ${name}`);
  return source.slice(start, end);
}

class LlmError extends Error {}
const bindings = {
  z$1: z,
  agentEvents: (ctx, agent) => { ctx.constructingAgent = agent; return ctx.dispatch; },
  createScope: ctx => ({ ctx }),
  assembleContextFor: (agent, signal) => ({ agent, signal }),
  renderContextSections: () => [],
  joinContextSections: () => '',
  renderPrompt: () => 'synthetic prompt',
  createSystemMessage: text => ({ role: 'system', content: [{ type: 'text', text }] }),
  ToolCallRecovery: sessionApi.ToolCallRecovery,
  LlmError,
  errorChain: error => error.message,
  deepFreeze: value => value,
  assertNever: value => { throw Error(`Unexpected ${value}`); },
};
const api = Function(...Object.keys(bindings), [
  region('inbox'), region('runtime-context'), region('agent'),
  'return {ReactLoopInbox, ReactLoopAgent, inboxProjectionDefinition};',
].join('\n'))(...Object.values(bindings));
const definition = api.inboxProjectionDefinition;
const ids = messages => messages.map(message => message.id);
const message = (id, attachment = false) => ({
  id, role: 'user', source: { kind: 'user', rpcId: `rpc-${id}` },
  content: [{ type: 'text', text: `synthetic input ${id}` },
    ...(attachment ? [{ type: 'image', mimeType: 'image/png', data: 'c3ludGhldGlj' },
      { type: 'file', path: '/synthetic/attachment.txt', name: 'attachment.txt' }] : [])],
});

function fixture({ events = [], assemble, preStep, prepareCall, failAppend, notify } = {}) {
  let state = definition.init();
  const log = [];
  const listeners = new Set();
  const notifications = [];
  const counters = { assembly: 0, preparation: 0, wake: 0 };
  let session;
  function observe(event) {
    state = definition.stateSchema.parse(definition.apply(state, event));
    log.push(structuredClone(event));
  }
  for (const event of events) observe(event);
  session = {
    id: 'synthetic-session',
    surface: { contentGeneration: 0, nodes: [] },
    append(type, data, intent = {}) {
      if (failAppend?.(type, data, log)) throw Error('synthetic storage failure');
      const event = { type, data: structuredClone(data), seq: log.length, time: '2026-01-01T00:00:00Z', ...intent };
      observe(event);
      if (intent.surfaceOp === 'append') session.surface.nodes.push(event.seq);
      for (const listener of listeners) listener(session, event);
      return event;
    },
    snapshotEvents: () => [...log],
    eventAt: seq => log[seq],
    requestHeader: () => undefined,
  };
  const projections = {
    stateOf(_session, key) {
      if (key === 'inbox') return state;
      if (key === 'turnBoundary') return { lastTurn: log.findLast(e => e.type === 'turn/start')?.data.turn ?? 0 };
      throw Error(`Unexpected projection ${key}`);
    },
  };
  const dispatch = {
    emit: (type, data) => { notifications.push({ type, data }); notify?.(type, data, ctx.constructingAgent); },
    serial: async () => {},
    waterfall: async (type, args, fallback) => {
      if (type === 'agent/pre-step' && preStep) return preStep(args, fallback);
      return fallback();
    },
  };
  const ctx = {
    dispatch, sessionProjections: projections,
    get: () => undefined,
    on: (type, listener) => { assert.equal(type, 'session/event'); listeners.add(listener); return () => listeners.delete(listener); },
    agents: { withInitiator: (_agent, fn) => fn() },
    systemPrompt: {
      async assemble(context) { counters.assembly++; return assemble ? assemble(context) : { tools: [] }; },
      refreshContext: assembly => assembly,
    },
    llm: {
      async prepareCall(config, signal) {
        counters.preparation++;
        return prepareCall ? prepareCall(config, signal) : { config };
      },
    },
  };
  const agent = new api.ReactLoopAgent(ctx, session.id, { provider: 'synthetic', model: 'test', reasoningEffort: 'max' }, session);
  // Exercise the real step/admission path, then stop before starting any real model request.
  agent.buildRequest = () => { throw Error('synthetic post-admission failure'); };
  const originalWake = agent.wakeDriver;
  agent.wakeDriver = function (...args) { counters.wake++; return originalWake.apply(this, args); };
  return { agent, session, log, notifications, counters, state: () => state };
}
function running(f) {
  f.agent.phase = { kind: 'running', turn: 1, step: 0, abort: new AbortController(), wakeRequested: false };
  f.session.append('turn/start', { turn: 1 });
}
function cold(events, options = {}) {
  const committed = structuredClone(events);
  const closers = sessionApi.interruptedTurnClosers(committed);
  return fixture({ ...options, events: [...committed, ...closers] });
}
function clientInbox(events) {
  const pending = { 'next-turn': [], 'next-step': [] };
  for (const event of events) if (event.type === 'agent/inbox/spliced') {
    const data = event.data;
    pending[data.target].splice(data.start, data.removedCount ?? 0, ...data.inserted);
  }
  return pending;
}
function assertClientSees(f) {
  const view = definition.wire.viewSchema.parse(definition.wire.view(f.state()));
  assert.deepEqual(Object.keys(view).sort(), ['next-step', 'next-turn']);
  assert.deepEqual(clientInbox(f.log), view);
}

for (const stage of ['assemble', 'prepare']) test(`real class ${stage} failure restores input once without automatic retry`, async () => {
  const fault = Error(`synthetic ${stage} failure`);
  const f = fixture(stage === 'assemble' ? { assemble: async () => { throw fault; } }
    : { prepareCall: async config => { assert.equal(config.reasoningEffort, 'max'); throw fault; } });
  const original = message('a', true);
  f.agent.followup(original);
  await f.agent.whenIdle();
  assert.equal(f.agent.status, 'idle');
  assert.deepEqual(f.agent.inbox.nextTurn, [original]);
  assert.deepEqual(f.state().inFlight, []);
  assert.equal(f.counters.wake, 1);
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.log.filter(e => e.type === 'turn/end').length, 1);
  assert.equal(f.notifications.filter(e => e.type === 'agent/error').length, 1);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.kind, 'error');
  const endIndex = f.log.findIndex(e => e.type === 'turn/end');
  const claimIndex = f.log.findIndex(e => e.type === 'agent/inbox/spliced' && e.data.removedCount);
  assert(f.log.slice(claimIndex + 1, endIndex).some(e => e.type === 'agent/inbox/spliced' && e.data.inserted[0]?.id === 'a'));
  assertClientSees(f);
  const count = f.log.length;
  assert.equal(f.agent.inbox.recover(), false);
  await Promise.resolve();
  assert.equal(f.log.length, count);
});

for (const stage of ['pre-step', 'refresh-context', 'system-message']) test(`all preparation boundaries recover: ${stage}`, async () => {
  const f = fixture({
    preStep: stage === 'pre-step' ? async () => { throw Error('synthetic plugin failure'); } : undefined,
    failAppend: stage === 'system-message' ? type => type === 'system/message' : undefined,
  });
  if (stage === 'refresh-context') f.agent.loopCtx.systemPrompt.refreshContext = () => { throw Error('synthetic refresh failure'); };
  f.agent.followup(message('a', true));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, [message('a', true)]);
  assert.equal(f.counters.wake, 1);
  assert.equal(f.log.filter(e => e.type === 'user/message').length, 0);
  // Every physical crash cut of the real failure sequence remains idempotent.
  const firstClaim = f.log.findIndex(e => e.type === 'agent/inbox/spliced' && e.data.removedCount);
  for (let cut = firstClaim + 1; cut <= f.log.length; cut++) {
    const resumed = cold(f.log.slice(0, cut));
    assert.deepEqual(resumed.agent.inbox.nextTurn, [message('a', true)]);
    assertClientSees(resumed);
  }
});

test('real prepareRequest preserves route and effort; explicit resume does not require resending original text', async () => {
  let fail = true;
  const f = fixture({ prepareCall: async config => {
    assert.deepEqual(config, { provider: 'synthetic', model: 'test', reasoningEffort: 'max' });
    if (fail) throw Error('unsupported synthetic configuration');
    return { config };
  } });
  f.agent.followup(message('a'));
  await f.agent.whenIdle();
  fail = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, []);
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['a']);
  assert.equal(f.counters.preparation, 2);
});

test('crash at every claim/admission/restore prefix replays original targets, order, identity and attachments', () => {
  const f = fixture();
  for (const id of ['s1', 's2']) f.agent.inbox.append('next-step', message(id, id === 's2'));
  for (const id of ['t1', 't2']) f.agent.inbox.append('next-turn', message(id));
  running(f);
  f.agent.inbox.claim('next-turn', 1);
  f.session.append('user/message', message('s1'), { surfaceOp: 'append' });
  f.session.append('step/end', { turn: 1, step: 1 });
  f.session.append('turn/end', { turn: 1, reason: { kind: 'error', error: { code: 'UNKNOWN', message: 'synthetic' } } });
  f.agent.inbox.recover();
  const start = f.log.findIndex(e => e.type === 'turn/start');
  for (let cut = start + 1; cut <= f.log.length; cut++) {
    const prefixLog = f.log.slice(0, cut);
    const admitted = prefixLog.some(e => e.type === 'user/message' && e.data.id === 's1');
    const resumed = cold(prefixLog);
    assert.deepEqual(ids(resumed.agent.inbox.nextStep), admitted ? ['s2'] : ['s1', 's2'], `cut ${cut}`);
    assert.deepEqual(ids(resumed.agent.inbox.nextTurn), ['t1', 't2'], `cut ${cut}`);
    assert.deepEqual(resumed.agent.inbox.nextStep.find(m => m.id === 's2'), message('s2', true));
    assert.equal(resumed.counters.wake, 0);
    assertClientSees(resumed);
    const again = cold(resumed.log);
    assert.deepEqual(again.log, resumed.log, `second replay cut ${cut}`);
  }
});

test('cold recovery insertion observers see a fully initialized idle agent', () => {
  const f = fixture();
  f.agent.inbox.append('next-turn', message('held'));
  running(f);
  f.agent.inbox.claim('next-turn', 1);
  let observed = 0;
  const resumed = cold(f.log, { notify: (type, data, agent) => {
    if (type !== 'agent/inbox/inserted') return;
    observed++;
    assert.equal(data.message.id, 'held');
    assert.equal(agent.status, 'idle');
    assert.equal(agent.phase.lastTurn, 1);
    assert(agent.runtimeContext);
    assert(agent.systemPrompt);
    assert.deepEqual(ids(agent.inbox.nextTurn), ['held']);
  } });
  assert.equal(observed, 1);
  assert.equal(resumed.counters.wake, 0);
});

test('partially admitted messages are never reinserted or admitted twice after a real step append failure', async () => {
  let fail = true;
  const f = fixture({ failAppend: (type, data) => type === 'user/message' && data.id === 's2' && fail });
  f.agent.inject(message('s1'));
  f.agent.inject(message('s2', true));
  f.agent.followup(message('t1'));
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextStep), ['s2']);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['t1']);
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['s1']);
  fail = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['s1', 's2', 't1']);
  assert.deepEqual(f.state().inFlight, []);
  assertClientSees(f);
});

test('restoration prepends before arrivals and next-step claim never steals a queued turn', () => {
  const f = fixture();
  f.agent.inbox.append('next-step', message('s1'));
  f.agent.inbox.append('next-step', message('s2'));
  f.agent.inbox.append('next-turn', message('t1'));
  f.agent.inbox.append('next-turn', message('t2'));
  running(f);
  assert.deepEqual(ids(f.agent.inbox.claim('next-turn', 1)), ['s1', 's2', 't1']);
  f.agent.inbox.append('next-step', message('s3'));
  f.agent.inbox.append('next-turn', message('t3'));
  f.agent.inbox.recover();
  assert.deepEqual(ids(f.agent.inbox.claim('next-step', 1)), ['s1', 's2', 's3']);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['t1', 't2', 't3']);
});

test('blocked and deliberately filtered plugin input is settled durably, not restored on later failure', async () => {
  const blocked = fixture({ preStep: async () => ({ kind: 'reject' }) });
  blocked.agent.followup(message('pwd'));
  await blocked.agent.whenIdle();
  assert.deepEqual(blocked.agent.inbox.nextTurn, []);
  assert.equal(blocked.log.find(e => e.type === 'turn/end').data.reason.kind, 'blocked');
  assert.equal(blocked.log.some(e => e.type === 'user/message'), false);
  assert.deepEqual(cold(blocked.log).agent.inbox.nextTurn, []);

  const filtered = fixture({
    preStep: async ({ messages }) => ({ kind: 'enter', messages: messages.filter(m => m.id !== 'consumed') }),
    prepareCall: async () => { throw Error('synthetic preparation failure'); },
  });
  filtered.agent.inject(message('consumed'));
  filtered.agent.followup(message('retained'));
  await filtered.agent.whenIdle();
  assert.deepEqual(filtered.agent.inbox.nextStep, []);
  assert.deepEqual(ids(filtered.agent.inbox.nextTurn), ['retained']);
  const marker = filtered.log.findIndex(e => e.data.settledIds?.includes('consumed'));
  const resumed = cold(filtered.log.slice(0, marker + 1));
  assert.deepEqual(resumed.agent.inbox.nextStep, []);
  assert.deepEqual(ids(resumed.agent.inbox.nextTurn), ['retained']);
});

test('plugin replacement is intentional consumption even if the replacement request fails', async () => {
  const f = fixture({ preStep: async () => ({ kind: 'enter', messages: [message('replacement')] }),
    prepareCall: async () => { throw Error('synthetic failure'); } });
  f.agent.followup(message('consumed'));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, []);
  assert.deepEqual(cold(f.log).agent.inbox.nextTurn, []);
});

for (const kind of ['user', 'disposed']) test(`cancel ${kind} recovers unadmitted claim but not explicitly canceled pending input`, async () => {
  let release;
  let entered;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({ assemble: async () => { entered(); await gate; return { tools: [] }; } });
  f.agent.followup(message('claimed', true));
  await inside;
  f.agent.inbox.append('next-turn', message('pending'));
  f.agent.cancel({ kind });
  release();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['claimed']);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.kind, 'aborted');
  assert.equal(f.counters.wake, 1);
  assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['claimed']);
  assertClientSees(f);
});

test('an explicit inbox remove/clear is not a claim and is never resurrected', async () => {
  const f = fixture();
  f.agent.inject(message('s'));
  f.agent.inbox.append('next-turn', message('t'));
  f.agent.cancel({ kind: 'user' });
  assert.equal(f.agent.inbox.hasPending, false);
  assert.equal(cold(f.log).agent.inbox.hasPending, false);
  await f.agent.runMaintenance(async () => {});
  assert.equal(f.agent.inbox.hasPending, false);
});

test('cancel followed by a new wake cannot turn recovered input into an automatic error storm', async () => {
  let release;
  let entered;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({ assemble: async () => { entered(); await gate; return { tools: [] }; } });
  f.agent.followup(message('claimed'));
  await inside;
  f.agent.cancel({ kind: 'user' });
  f.agent.followup(message('new'));
  release();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['claimed', 'new']);
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.agent.status, 'idle');
});

test('failed restore append is contained once and cold resume can finish the durable claim', async () => {
  let rejectRestore = false;
  const f = fixture({ assemble: async () => { rejectRestore = true; throw Error('synthetic assemble failure'); },
    failAppend: (type, data) => rejectRestore && type === 'agent/inbox/spliced' && data.inserted.length > 0 });
  f.agent.followup(message('a'));
  await f.agent.whenIdle();
  assert.equal(f.agent.status, 'idle');
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.error.message, 'synthetic assemble failure');
  assert.deepEqual(f.notifications.filter(e => e.type === 'agent/error').map(e => e.data.error.message),
    ['synthetic assemble failure', 'synthetic storage failure']);
  assert.deepEqual(ids(f.state().inFlight.map(claim => claim.message)), ['a']);
  assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['a']);
});

test('failed live restore blocks a new turn until the held input can be recovered', async () => {
  let failPrepare = true;
  let failRestore = true;
  const f = fixture({
    prepareCall: async config => { if (failPrepare) throw Error('synthetic prepare failure'); return { config }; },
    failAppend: (type, data, log) => failRestore && type === 'agent/inbox/spliced' && data.inserted.length > 0
      && log.some(e => e.type === 'turn/start'),
  });
  f.agent.followup(message('held'));
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.claimed), ['held']);
  const turns = f.log.filter(e => e.type === 'turn/start').length;
  assert.throws(() => f.agent.wakeDriver(), /synthetic storage failure/);
  assert.equal(f.agent.status, 'idle');
  assert.equal(f.log.filter(e => e.type === 'turn/start').length, turns);
  assert.deepEqual(ids(f.agent.inbox.claimed), ['held']);
  assert.throws(() => f.agent.followup(message('new')), /synthetic storage failure/);
  assert.deepEqual(f.agent.inbox.nextTurn, [], 'a rejected admission must not leave its new input queued');
  assert.equal(f.log.some(e => e.type === 'agent/inbox/spliced' && e.data.inserted.some(m => m.id === 'new')), false);
  failPrepare = false;
  failRestore = false;
  f.agent.followup(message('new'));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.claimed, []);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['new']);
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['held', 'new']);
});

test('real controller prompt retries are idempotent while claimed, restored and admitted', async () => {
  const controllerPath = process.env.INPUT_RECOVERY_CONTROLLER_MODULE
    ?? resolve(dirname(modulePath), '../../dsh-api-session-controller/lib/index.js');
  const controllerSource = readFileSync(controllerPath, 'utf8');
  const start = controllerSource.indexOf('//#region lib/types/commands.js');
  const end = controllerSource.indexOf('//#endregion', start);
  assert(start >= 0 && end > start);
  assert.match(controllerSource.slice(start, end), /agent\.inbox\.claimed\?\.some\(matches\)/);
  let nextId = 0;
  class RemoteError extends Error {}
  const { SessionCommandController, hasPromptRequest } = Function('createUserMessage', 'RemoteError', 'remoteErrorOf', 'AttachmentError',
    controllerSource.slice(start, end) + '\nreturn {SessionCommandController, hasPromptRequest};')
    (input => ({ ...input, id: `synthetic-rpc-${++nextId}`, role: 'user' }), RemoteError, () => undefined, class extends Error {});
  let release;
  let entered;
  let failPrepare = true;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({
    assemble: async () => { entered(); await gate; return { tools: [] }; },
    prepareCall: async config => { if (failPrepare) throw Error('synthetic prepare failure'); return { config }; },
  });
  let admissions = 0;
  const ctx = {
    agents: { get: () => f.agent },
    attachments: { admitPromptContent: async content => { admissions++; return content; } },
    fileUploads: {
      resolve: () => undefined,
      bindPrompt: () => ({ commit() {}, [Symbol.dispose]() {} }),
    },
  };
  const controller = new SessionCommandController(ctx, {}, '/synthetic');
  controller.resolveAgent = async () => f.agent;
  const request = (requestId, text) => ({ sessionId: f.agent.id, requestId, mode: 'followup', content: [{ type: 'text', text }] });
  const submit = (requestId, text) => controller.prompt(request(requestId, text), { kind: 'user', rpcId: requestId });
  await submit('rpc-a', 'original A');
  await inside;
  assert.equal(hasPromptRequest(f.agent, 'rpc-a'), true);
  await submit('rpc-a', 'transport retry B must not replace A');
  assert.equal(admissions, 1);
  assert.equal(nextId, 1);
  // Identical text with a different identity is a distinct prompt, not a duplicate.
  await submit('rpc-b', 'original A');
  assert.equal(admissions, 2);
  release();
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn.map(m => m.source.rpcId), ['rpc-a', 'rpc-b']);
  await submit('rpc-a', 'retry after restored');
  assert.equal(admissions, 2);
  failPrepare = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  await submit('rpc-a', 'retry after admitted');
  assert.equal(admissions, 2);
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  const admitted = f.log.filter(e => e.type === 'user/message').map(e => e.data);
  assert.deepEqual(admitted.map(m => m.source.rpcId), ['rpc-a', 'rpc-b']);
  assert.deepEqual(admitted.map(m => m.content[0].text), ['original A', 'original A']);
  // Older Agent drivers without the optional claimed view remain supported.
  assert.equal(hasPromptRequest({ inbox: { nextTurn: [], nextStep: [] }, session: { snapshotEvents: () => [] } }, 'rpc-a'), false);
});

test('real Session and JSONL codec preserve consumption markers and flush constructor recovery before publication', async () => {
  const catalogApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session-format-catalog/lib/index.js')));
  const formatApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session-format-v3-to-v4/lib/index.js')));
  const persistenceApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session-persistence/lib/index.js')));
  const jsonlSource = readFileSync(join(deps, 'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js'), 'utf8');
  const scannerStart = jsonlSource.indexOf('const HEADER_REQUIRED_KEYS');
  const scannerEnd = jsonlSource.indexOf('//#endregion', jsonlSource.indexOf('function scanLog(', scannerStart));
  assert(scannerStart >= 0 && scannerEnd > scannerStart);
  const codecBindings = { ...catalogApi, ...formatApi, ...persistenceApi, ...sessionApi, isAbsolute, join };
  delete codecBindings.default;
  const codec = Function(...Object.keys(codecBindings), jsonlSource.slice(scannerStart, scannerEnd)
    + '\nreturn {toHeaderLine, eventLines, scanLog};')(...Object.values(codecBindings));
  const suffixStart = source.indexOf('\tasync appendUnstoredSuffix(');
  const suffixEnd = source.indexOf('\n\t}', suffixStart) + 3;
  assert(suffixStart >= 0 && suffixEnd > suffixStart);
  const Factory = Function('SessionLogOffset', 'return class {' + source.slice(suffixStart, suffixEnd) + '\n}')
    (sessionApi.SessionLogOffset);
  const projectionOf = session => session.snapshotEvents().reduce((state, event) => definition.apply(state, event), definition.init());
  const dispatch = { emit() {} };
  const ctx = {
    dispatch,
    sessionProjections: { stateOf: (session, key) => key === 'inbox' ? projectionOf(session) : { lastTurn: 1 } },
    on: () => () => {},
  };
  const live = sessionApi.Session.create('synthetic-jsonl-recovery');
  const inbox = new api.ReactLoopInbox(ctx.sessionProjections, live, dispatch);
  inbox.append('next-step', message('consumed'));
  inbox.append('next-turn', message('retained'));
  live.append('turn/start', { turn: 1 });
  inbox.claim('next-turn', 1);
  inbox.settle(['consumed']);
  const root = await mkdtemp(join(tmpdir(), 'dsh-input-codec-'));
  const file = join(root, 'synthetic.jsonl');
  try {
    await writeFile(file, JSON.stringify(codec.toHeaderLine(live.header)) + '\n' + codec.eventLines(live.snapshotEvents()) + '\n');
    const loaded = codec.scanLog(await readFile(file));
    assert.deepEqual(loaded.events.find(e => e.data.settledIds)?.data.settledIds, ['consumed']);
    const closers = sessionApi.interruptedTurnClosers(loaded.events);
    await appendFile(file, codec.eventLines(closers) + '\n');
    const seed = [...loaded.events, ...closers];
    const restored = sessionApi.Session.create(live.id, seed, loaded.meta);
    const agent = new api.ReactLoopAgent(ctx, live.id, {}, restored);
    assert.deepEqual(ids(agent.inbox.nextTurn), ['retained']);
    assert.deepEqual(agent.inbox.nextStep, []);
    assert.equal(agent.status, 'idle');
    const constructorSuffix = restored.snapshotEvents().slice(seed.length);
    assert(constructorSuffix.some(e => e.type === 'agent/inbox/spliced' && e.data.inserted[0]?.id === 'retained'));
    // This exact factory method runs after construction/setup and before publish.
    const stored = { storedCount: seed.length, handle: { append: async events => appendFile(file, codec.eventLines(events) + '\n') } };
    await new Factory().appendUnstoredSuffix(stored, restored);
    assert.equal(stored.storedCount, restored.snapshotEvents().length);
    const persisted = codec.scanLog(await readFile(file));
    assert.deepEqual(persisted.events, restored.snapshotEvents());
    const second = sessionApi.Session.create(live.id, persisted.events, persisted.meta);
    const secondAgent = new api.ReactLoopAgent(ctx, live.id, {}, second);
    assert.deepEqual(ids(secondAgent.inbox.nextTurn), ['retained']);
    assert.deepEqual(secondAgent.inbox.nextStep, []);
    assert.equal(second.snapshotEvents().filter(e => e.type === 'agent/inbox/spliced' && e.data.inserted[0]?.id === 'retained').length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('real buildForkSeed preserves claims at every prefix and never restores admitted identities twice', () => {
  const projectionOf = session => session.snapshotEvents().reduce((state, event) => definition.apply(state, event), definition.init());
  const ctx = {
    dispatch: { emit() {} },
    sessionProjections: { stateOf: (session, key) => key === 'inbox' ? projectionOf(session) : { lastTurn: 1 } },
    on: () => () => {},
  };
  const live = sessionApi.Session.create('synthetic-fork-parent');
  const inbox = new api.ReactLoopInbox(ctx.sessionProjections, live, ctx.dispatch);
  inbox.append('next-step', message('s1'));
  inbox.append('next-step', message('s2', true));
  inbox.append('next-turn', message('t1'));
  inbox.append('next-turn', message('t2'));
  live.append('turn/start', { turn: 1 });
  inbox.claim('next-turn', 1);
  live.append('user/message', message('s1'), { surfaceOp: 'append' });
  live.append('user/message', message('t1'), { surfaceOp: 'append' });
  const events = live.snapshotEvents();
  const firstTurn = events.findIndex(e => e.type === 'turn/start');
  for (let boundary = firstTurn; boundary < events.length; boundary++) {
    const seed = sessionApi.buildForkSeed(events, boundary);
    assert.equal(seed.at(-1).data.reason.kind, 'forked');
    const header = { ...live.header, id: 'synthetic-fork-child', isSeeded: true, parentSession: live.id };
    const child = sessionApi.Session.create(header.id, seed, header, boundary + 1);
    const agent = new api.ReactLoopAgent(ctx, header.id, {}, child);
    const admitted = new Set(events.slice(0, boundary + 1).filter(e => e.type === 'user/message').map(e => e.data.id));
    assert.deepEqual(ids(agent.inbox.nextStep), ['s1', 's2'].filter(id => !admitted.has(id)), `fork boundary ${boundary}`);
    assert.deepEqual(ids(agent.inbox.nextTurn), ['t1', 't2'].filter(id => !admitted.has(id)), `fork boundary ${boundary}`);
    assert.deepEqual(agent.inbox.nextStep.find(m => m.id === 's2'), message('s2', true));
    assert.equal(agent.status, 'idle');
    const replay = sessionApi.Session.create(header.id, child.snapshotEvents(), header, boundary + 1);
    const before = replay.snapshotEvents();
    const resumed = new api.ReactLoopAgent(ctx, header.id, {}, replay);
    assert.deepEqual(ids(resumed.inbox.nextStep), ids(agent.inbox.nextStep));
    assert.deepEqual(ids(resumed.inbox.nextTurn), ids(agent.inbox.nextTurn));
    assert.deepEqual(replay.snapshotEvents(), before, 'second attachment must not emit duplicate recovery splices');
  }
});

test('real buildForkSeed never revives blocked or explicitly consumed plugin input', () => {
  for (const kind of ['blocked', 'settled-before-terminal']) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('consumed'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    if (kind === 'blocked') f.session.append('turn/end', { turn: 1, reason: { kind: 'blocked' } });
    else f.agent.inbox.settle(['consumed']);
    const seed = sessionApi.buildForkSeed(f.log, f.log.length - 1);
    const forked = fixture({ events: seed });
    assert.equal(forked.agent.inbox.hasPending, false);
    assert.deepEqual(forked.state().inFlight, []);
  }
});

test('unrecognized terminal reasons retain claims rather than silently declaring consumption', () => {
  for (const reason of [null, { kind: 'future-non-success-terminal' }]) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('retained'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    f.session.append('turn/end', { turn: 1, reason });
    assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['retained']);
  }
});

test('successful no-echo consumption from old histories stays consumed; wire schema remains unchanged', () => {
  for (const kind of ['blocked', 'completed', 'max-tokens']) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('consumed'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    f.session.append('turn/end', { turn: 1, reason: { kind } });
    assert.equal(cold(f.log).agent.inbox.hasPending, false);
  }
  assert.equal(definition.stateVersion, 2);
});
