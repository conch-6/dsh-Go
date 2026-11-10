import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';
import { createCompanionPromptContext, FULL_PRESET } from '../bridge/dsh-go-bridge/lib/companion/prompt-context.js';

const path = '/dsh-go/v1/companion/prompt-context';
async function fixture(t) {
  const clock = Date.UTC(2026, 10, 8, 5);
  const human = { type: 'user/message', time: clock - 24 * 3600000, data: { source: { kind: 'user' } } };
  const synthetic = { type: 'user/message', time: clock - 1000, data: { source: { kind: 'time-context' } } };
  const state = { resolves: 0, recalls: 0, preset: FULL_PRESET, found: true, retired: false };
  const agent = { id: 's', session: { id: 's', seq: 2, eventAt: seq => [human, synthetic][seq] } };
  const service = createCompanionPromptContext({ now: () => clock, instanceId: 'boot' });
  const ctx = { get(name) {
    return {
      connection: { admit(req) {
        return req.headers.authorization === 'owner' ? { peer: { principal: { kind: 'owner' } } } :
          req.headers.authorization === 'reader' ? { peer: { principal: { kind: 'reader' } } } : { rejection: 401 };
      } },
      sessionController: { async resolveAgent() { state.resolves++; return state.found ? { agent } : { error: { code: 'session/not-found' } }; } },
      agentPresets: { presetForSession: () => state.preset },
      agents: { get: () => state.retired ? undefined : agent },
    }[name];
  } };
  const store = { async getContext({ query, limit }) {
    state.recalls++; assert.equal(query, '茶'); assert.equal(limit, 6);
    await state.recallGate;
    return { memories: [{ text: '喜欢无糖茶', expiresAt: null }] };
  } };
  const route = createCompanionRoutes({ ctx, promptContext: service, store,
    send(res, status, body) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); } });
  const server = createServer((req, res) => { void route.handle(req, res, new URL(req.url, 'http://local').pathname); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  async function request({ method = 'GET', auth = 'owner', body, type = 'application/json', session = 's' } = {}) {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${path}?sessionId=${session}`, {
      method, headers: { authorization: auth, 'content-type': type },
      ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }),
    });
    return { status: res.status, body: await res.json() };
  }
  const body = extra => ({ v: 1, sessionId: 's', requestId: 'r', instanceId: 'boot', events: [], ...extra });
  return { clock, state, service, request, body, agent };
}

test('owner admission precedes resolution and recall; reader and anonymous cannot probe', async t => {
  const f = await fixture(t);
  for (const [auth, status] of [['reader', 403], ['anonymous', 401]]) {
    assert.equal((await f.request({ auth })).status, status);
    assert.equal((await f.request({ auth, method: 'POST', body: f.body({ query: '茶' }) })).status, status);
  }
  assert.equal(f.state.resolves, 0); assert.equal(f.state.recalls, 0);
  assert.equal((await f.request()).body.instanceId, 'boot');
  f.state.retired = true;
  assert.equal((await f.request()).body.error.code, 'companion/session-unavailable');
  f.state.retired = false;
  f.state.preset = 'some-other-preset';
  assert.equal((await f.request()).body.error.code, 'companion/wrong-session');
  f.state.found = false;
  const absent = await f.request();
  assert.equal(absent.status, 404); assert.equal(absent.body.error.code, 'companion/session-unavailable');
});

test('real HTTP validation rejects malformed and oversized data before resolution', async t => {
  const f = await fixture(t);
  for (const [body, type, status] of [[f.body({}), 'text/plain', 415], ['{', 'application/json', 400],
    ['x'.repeat(32769), 'application/json', 413], [f.body({ query: '🐋'.repeat(257) }), 'application/json', 400]]) {
    assert.equal((await f.request({ method: 'POST', body, type })).status, status);
  }
  assert.equal((await f.request({ method: 'DELETE' })).status, 405);
  assert.equal(f.state.resolves, 0); assert.equal(f.state.recalls, 0);
});

test('a retired agent during asynchronous recall cannot acquire context or settings', async t => {
  const f = await fixture(t);
  let release;
  f.state.recallGate = new Promise(resolve => { release = resolve; });
  const pending = f.request({ method: 'POST', body: f.body({ query: '茶',
    profile: { persona: 'changed', name: '', callMe: '', moves: '' }, expectedProfileRevision: 0 }) });
  while (!f.state.recalls) await new Promise(resolve => setImmediate(resolve));
  f.state.retired = true; release();
  assert.equal((await pending).body.error.code, 'companion/session-unavailable');
  assert.equal(f.service.profile(f.agent), undefined);
});

test('prepared recall and last-human gap bind to the exact subsequent owner prompt', async t => {
  const f = await fixture(t);
  assert.equal((await f.request({ method: 'POST', body: f.body({ query: '茶' }) })).status, 200);
  assert.equal(f.service.render(f.agent), '');
  f.service.claim(f.agent, { source: { kind: 'user', rpcId: 'other' } }, 1);
  assert(!f.service.render(f.agent).includes('喜欢无糖茶'), 'another request cannot claim this recall');
  assert.match(f.service.render(f.agent), /"idleSinceHumanMinutes":1440/, 'human gap is session state, even without a sidecar');
  f.service.claim(f.agent, { source: { kind: 'user', rpcId: 'r' } }, 2);
  assert.match(f.service.render(f.agent), /喜欢无糖茶/);
  assert.match(f.service.render(f.agent), /"idleSinceHumanMinutes":1440/);
  assert.equal(f.state.recalls, 1);
});

test('an unloaded bridge cannot acknowledge a delayed recall write', async t => {
  const f = await fixture(t);
  let release;
  f.state.recallGate = new Promise(resolve => { release = resolve; });
  const pending = f.request({ method: 'POST', body: f.body({ query: '茶',
    profile: { persona: 'late', name: '', callMe: '', moves: '' }, expectedProfileRevision: 0 }) });
  while (!f.state.recalls) await new Promise(resolve => setImmediate(resolve));
  f.service.clear(); release();
  assert.equal((await pending).status, 503);
  assert.equal(f.service.profile(f.agent), undefined);
});
