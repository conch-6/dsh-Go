import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { runInNewContext } from 'node:vm';

const require = createRequire(import.meta.url);
const source = readFileSync(new URL('../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/SafeMode.kt', import.meta.url), 'utf8');
const script = source.match(/const val PLUGINS_SCRIPT = """([\s\S]*?)"""/)[1];

// Run the shipped helper against real Node streams. Only the child and clock
// are controlled; no DSH installation, model, Android or real waiting is needed.
function trial(t) {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  t.after(() => { child.stdout.destroy(); child.stderr.destroy(); });
  const kills = [];
  child.kill = signal => { kills.push(signal); return true; };
  let now = 1000;
  let tick;
  let status;
  let stdout = '';
  const exited = {};
  runInNewContext(script, {
    require: name => name === 'child_process' ? { spawn: () => child } : require(name),
    Date: { now: () => now },
    setInterval: callback => { tick = callback; return 1; },
    clearInterval: () => {},
    setTimeout: () => ({ unref() {} }),
    process: {
      argv: ['node', 'helper', 'trial'],
      env: { DSH_APP_PATCH: '/absent-trial-fixture.patch.yml', TRIAL_HOLD: '0', TRIAL_LIMIT: '1' },
      stdout: { write: text => { stdout += text; } },
      stderr: { write: () => {} },
      exit: code => { status = code; throw exited; },
    },
  });
  function run(action) {
    try { action(); } catch (error) { if (error !== exited) throw error; }
  }
  return {
    child, kills,
    tick: () => run(() => { now += 1500; tick(); }),
    exit: () => run(() => child.emit('exit', 0, null)),
    get status() { return status; },
    get stdout() { return stdout; },
  };
}

for (const stream of ['stdout', 'stderr']) {
  test(`trial recognizes a login marker split across ${stream} chunks`, t => {
    const run = trial(t);
    run.child[stream].write('http://127.0.0.1:12345/?to');
    run.child[stream].write('ken=fixture-only\n');
    run.tick();
    assert.deepEqual(run.kills, ['SIGTERM'], 'the complete login line should enter the healthy hold path');
    run.exit();
    assert.equal(run.status, 0, run.stdout);
    assert.match(run.stdout, /PASS:/);
  });
}

test('trial preserves an ordinary complete login line', t => {
  const run = trial(t);
  run.child.stdout.write('dsh web: http://127.0.0.1:12345/?token=fixture-only\n');
  run.tick();
  assert.deepEqual(run.kills, ['SIGTERM']);
  run.exit();
  assert.equal(run.status, 0, run.stdout);
});

test('trial keeps stdout and stderr line fragments separate', t => {
  const run = trial(t);
  run.child.stdout.write('to');
  run.child.stderr.write('ken=fixture-only\n');
  run.child.stdout.write('\n');
  run.tick();
  assert.deepEqual(run.kills, ['SIGKILL']);
  assert.equal(run.status, 1);
});

test('trial still fails when no login line arrives', t => {
  const run = trial(t);
  run.child.stdout.write('ordinary startup output\n');
  run.tick();
  assert.deepEqual(run.kills, ['SIGKILL']);
  assert.equal(run.status, 1);
  assert.match(run.stdout, /FAIL:/);
});
