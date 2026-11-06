import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, createConnection } from 'node:net';
import { EventEmitter, once } from 'node:events';
import { WsConnection } from '../bridge/dsh-go-bridge/lib/native/ws.js';

function timers(t) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const set = globalThis.setTimeout, clear = globalThis.clearTimeout;
  const active = new Set();
  let scheduled = 0;
  t.mock.method(globalThis, 'setTimeout', (fn, ms, ...args) => {
    let timer;
    timer = set(() => { active.delete(timer); fn(...args); }, ms);
    if (ms === 1000) { scheduled++; active.add(timer); }
    return timer;
  });
  t.mock.method(globalThis, 'clearTimeout', timer => { active.delete(timer); return clear(timer); });
  return { active, scheduled: () => scheduled };
}

test('ws close retires the destroy deadline after a real TCP close', async t => {
  const tracked = timers(t);
  const server = createServer();
  const sockets = [];
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const accepted = once(server, 'connection');
  const client = createConnection(server.address().port, '127.0.0.1');
  sockets.push(client);
  client.resume();
  const [socket] = await accepted;
  sockets.push(socket);
  const ws = new WsConnection(socket, Buffer.alloc(0), 4096);
  const closed = once(socket, 'close');
  ws.close();
  await closed;
  assert.equal(ws.closed, true);
  assert.equal(socket.destroyed, true);
  assert.equal(tracked.scheduled(), 1);
  t.diagnostic(`actual TCP close: pending destroy timers=${tracked.active.size}`);
  const destroy = t.mock.method(socket, 'destroy');
  t.mock.timers.tick(1000);
  assert.equal(destroy.mock.callCount(), 0, 'completed socket must not be destroyed again by a stale deadline');
  assert.equal(tracked.active.size, 0);
});

test('ws logical close retains its deadline until the socket actually closes', t => {
  const tracked = timers(t);
  const socket = new EventEmitter();
  socket.write = () => {};
  socket.end = () => {};
  let destroyed = 0;
  socket.destroy = () => { destroyed++; socket.emit('close'); };
  const ws = new WsConnection(socket, Buffer.alloc(0), 4096);
  ws.close();
  assert.equal(ws.closed, true);
  assert.equal(tracked.active.size, 1);
  t.mock.timers.tick(999);
  assert.equal(destroyed, 0);
  t.mock.timers.tick(1);
  assert.equal(destroyed, 1);
  assert.equal(tracked.active.size, 0);
});
