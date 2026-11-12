import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { assetUrl, blobKey } from '../src/workshop-common';
import { STATE_KEY } from '../src/workshop-state';
import { makeCtx, makeEnv } from './fakes';
import { PetBucket } from './pet-market-fakes';
import { companion, metaFor, pet, petManifest } from './workshop-fixtures';

const API = '/api/workshop/v1';
let forumUser = 42;
beforeEach(() => {
  forumUser = 42;
  vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify({ current_user: { id: forumUser, username: `synthetic-${forumUser}` } })));
});
afterEach(() => vi.restoreAllMocks());
function setup() {
  const bucket = new PetBucket(), f = makeEnv({ BUCKET: bucket as unknown as R2Bucket });
  const call = (path: string, method = 'GET', body?: object | Uint8Array, admin = false, extra: Record<string, string> = {}) => worker.fetch(new Request('https://example.org' + path, {
    method, headers: { ...(path.startsWith(API) ? { 'User-Api-Key': 'synthetic-forum-key', 'X-Workshop-Forum-Origin': 'https://forum.dshtui.com' } : {}), ...(admin ? { 'X-Admin-Key': f.env.ADMIN_KEY! } : {}),
      ...(body ? { 'Content-Type': body instanceof Uint8Array ? 'application/zip' : 'application/json' } : {}), ...extra },
    ...(body ? { body: body instanceof Uint8Array ? body : JSON.stringify(body) } : {}),
  }), f.env, makeCtx().ctx);
  let serial = 0;
  const create = async (bytes = pet(), overrides = {}, requestId = `synthetic_request_${++serial}`) => {
    const meta = metaFor(bytes, overrides), response = await call(API + '/submissions', 'POST', { ...meta, requestId });
    expect(response.status).toBe(201); const { submission } = await response.json() as any; return { sid: submission.submissionId, meta, bytes, requestId };
  };
  const upload = async (item: Awaited<ReturnType<typeof create>>) => {
    const response = await call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes); expect(response.status).toBe(200); return await response.json() as any;
  };
  const review = (sid: string, decision = 'approve') => call(`${API}/admin/submissions/${sid}/review`, 'POST', { decision, reason: 'Synthetic moderation evidence' }, true);
  const publish = async (bytes = pet(), overrides = {}) => { const item = await create(bytes, overrides); await upload(item); expect((await review(item.sid)).status).toBe(200); return item; };
  const state = () => JSON.parse(new TextDecoder().decode(bucket.objects.get(STATE_KEY)!.bytes));
  return { ...f, bucket, call, create, upload, review, publish, state };
}

it('starts with both capabilities enabled and keeps old pet routes separate', async () => {
  const f = setup();
  expect(await (await f.call(API + '/capabilities')).json()).toMatchObject({ schema: 1, features: { uploads: true, companion: true }, maxMocVersion: 6 });
  expect(await (await f.call('/market/workshop.json')).json()).toMatchObject({ entries: [], withdrawn: [] });
  expect(f.dl.objects.size).toBe(0);
  expect((await f.call('/market/pets.json')).status).toBe(404);
});
it('requires the forum assertion at every author identity entry before any upstream call', async () => {
  const f = setup(), sid = '0123456789abcdef0123456789abcdef';
  const routes = [
    ['/submissions', 'GET'], ['/submissions', 'POST'], [`/submissions/${sid}`, 'GET'],
    [`/submissions/${sid}/archive`, 'PUT'], [`/submissions/${sid}/withdraw`, 'POST'], ['/reports', 'POST'],
  ] as const;
  for (const expected of [undefined, '', 'https://another-forum.example']) {
    for (const [path, method] of routes) {
      const response = await worker.fetch(new Request('https://example.org' + API + path, {
        method, headers: { 'User-Api-Key': 'synthetic-forum-key', ...(expected === undefined ? {} : { 'X-Workshop-Forum-Origin': expected }) },
      }), f.env, makeCtx().ctx);
      expect(response.status).toBe(409);
      expect(await response.json()).toEqual({ error: 'workshop_forum_origin' });
    }
  }
  expect(fetch).not.toHaveBeenCalled(); expect(f.bucket.objects.size).toBe(0);
});
it('checks the configured forum again after capabilities and never routes from the assertion', async () => {
  const f = setup(), announced = await (await f.call(API + '/capabilities')).json() as any;
  expect(announced.forumOrigin).toBe('https://forum.dshtui.com');
  f.env.WORKSHOP_FORUM_URL = 'https://another-forum.example';
  const changed = await f.call(API + '/submissions');
  expect(changed.status).toBe(409); expect(await changed.json()).toEqual({ error: 'workshop_forum_origin' });
  expect(fetch).not.toHaveBeenCalled();
  const current = await f.call(API + '/submissions', 'GET', undefined, false, { 'X-Workshop-Forum-Origin': 'https://another-forum.example' });
  expect(current.status).toBe(200);
  expect(vi.mocked(fetch).mock.calls.map(([url]) => url)).toEqual(['https://another-forum.example/session/current.json']);
});
it('compares the canonical IPv6 forum but forwards only the configured destination and allowed headers', async () => {
  const f = setup(); f.env.WORKSHOP_FORUM_URL = 'https://[2001:0db8:0000:0000:0000:0000:0000:0001]:443/';
  const announced = await (await f.call(API + '/capabilities')).json() as any;
  expect(announced.forumOrigin).toBe('https://[2001:db8::1]');
  const response = await f.call(API + '/submissions', 'GET', undefined, false, { 'X-Workshop-Forum-Origin': announced.forumOrigin });
  expect(response.status).toBe(200);
  const [url, init] = vi.mocked(fetch).mock.calls[0]!;
  expect(url).toBe('https://[2001:db8::1]/session/current.json');
  expect(init?.headers).toEqual({ 'User-Api-Key': 'synthetic-forum-key', Accept: 'application/json' });
  expect(init?.redirect).toBe('manual'); expect(fetch).toHaveBeenCalledTimes(1);
});
it('keeps public queries and the independent admin gate free of author assertion requirements', async () => {
  const f = setup();
  for (const path of [API + '/capabilities', '/market/workshop.json']) {
    expect((await worker.fetch(new Request('https://example.org' + path), f.env, makeCtx().ctx)).status).toBe(200);
  }
  const admin = await worker.fetch(new Request('https://example.org' + API + '/admin/reports', {
    headers: { 'X-Admin-Key': f.env.ADMIN_KEY! },
  }), f.env, makeCtx().ctx);
  expect(admin.status).toBe(200); expect(fetch).not.toHaveBeenCalled();
});
it('binds idempotency, fixed forum identity and metadata without retaining the key', async () => {
  const f = setup(), item = await f.create();
  const same = await f.call(API + '/submissions', 'POST', { ...item.meta, requestId: item.requestId }); expect(same.status).toBe(200);
  const changed = await f.call(API + '/submissions', 'POST', { ...item.meta, title: { zh: '变更', en: 'Changed' }, requestId: item.requestId }); expect(changed.status).toBe(409);
  const [origin, init] = vi.mocked(fetch).mock.calls[0]!;
  expect(origin).toBe('https://forum.dshtui.com/session/current.json'); expect(init?.redirect).toBe('manual');
  expect(init?.headers).toEqual({ 'User-Api-Key': 'synthetic-forum-key', Accept: 'application/json' });
  expect(JSON.stringify(f.state())).not.toContain('synthetic-forum-key');
  expect(f.state().audit[0]).toMatchObject({ action: 'create', actor: { forumUserId: 42 }, submissionId: item.sid });
  forumUser = 43; expect((await f.call(`${API}/submissions/${item.sid}`)).status).toBe(404);
  expect((await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes)).status).toBe(404);
});
it('retains optional display metadata through creation and publication without embedding it in the pack', async () => {
  const f = setup(), fields = { description: 'A small companion', tags: ['pet', '猫'] };
  const item = await f.publish(pet(), fields);
  expect(f.state().submissions[0].metadata).toMatchObject(fields);
  const response = await f.call(`${API}/submissions/${item.sid}`);
  expect((await response.json() as any).submission.metadata).toMatchObject(fields);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0]).toMatchObject(fields);
  const repeated = await f.call(API + '/submissions', 'POST', { tags: fields.tags, description: fields.description, ...item.meta, requestId: item.requestId });
  expect(repeated.status).toBe(200);
});
it('exposes bytes only after review and serves conditional/Range without leaking pending archives', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  const path = assetUrl(item.meta);
  expect(f.bucket.objects.has(blobKey(item.meta.sha256))).toBe(true);
  for (const method of ['GET', 'HEAD']) expect((await f.call(path, method)).status).toBe(404);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`)).status).toBe(401);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`, 'GET', undefined, true)).status).toBe(200);
  expect((await f.review(item.sid)).status).toBe(200);
  const body = await f.call(path), tag = body.headers.get('ETag')!; expect(Buffer.from(await body.arrayBuffer())).toEqual(item.bytes);
  const range = await f.call(path, 'GET', undefined, false, { Range: 'bytes=10-19', 'If-Range': tag });
  expect(range.status).toBe(206); expect(Buffer.from(await range.arrayBuffer())).toEqual(item.bytes.subarray(10, 20));
  expect((await f.call(path, 'GET', undefined, false, { Range: 'bytes=10-', 'If-Range': '"changed"' })).status).toBe(200);
  expect((await f.call(path, 'HEAD', undefined, false, { 'If-None-Match': tag })).status).toBe(304);
  const head = await f.call(path, 'HEAD'); expect(head.status).toBe(200); expect(await head.text()).toBe('');
  const catalog = await f.call('/market/workshop.json'); const entry = (await catalog.json() as any).entries[0]; expect(entry.url).toBe(path); expect(entry).not.toHaveProperty('rightsConfirmed');
  expect(f.dl.objects.size).toBe(0);
});
it('refuses the admin routes when the configured key is shorter than the share API allows', async () => {
  for (const key of [undefined, 'short', 'x'.repeat(31)]) {
    const weak = makeEnv({ ADMIN_KEY: key, BUCKET: new PetBucket() as unknown as R2Bucket });
    const response = await worker.fetch(new Request(`https://example.org${API}/admin/reports`, {
      headers: { 'User-Api-Key': 'synthetic-forum-key', ...(key ? { 'X-Admin-Key': key } : {}) },
    }), weak.env, makeCtx().ctx);
    expect(response.status).toBe(503);
  }
});
it('records reports, rejects before publication, and allows owner withdrawal while uploads are paused', async () => {
  const f = setup(), item = await f.publish();
  const report = await f.call(API + '/reports', 'POST', { kind: 'pet', id: 'sample', version: '1.0.0', reason: 'Synthetic rights complaint' }); expect(report.status).toBe(201);
  expect((await (await f.call(API + '/admin/reports', 'GET', undefined, true)).json() as any).reports).toHaveLength(1);
  f.env.WORKSHOP_UPLOAD_ENABLED = '0';
  expect(await (await f.call(API + '/submissions', 'POST', {})).json()).toEqual({ error: 'workshop_upload_disabled' });
  expect((await f.call(`${API}/submissions/${item.sid}/withdraw`, 'POST', { reason: 'Synthetic owner withdrawal' })).status).toBe(200);
  expect((await f.call(assetUrl(item.meta))).status).toBe(404);
  const catalog = await (await f.call('/market/workshop.json')).json() as any; expect(catalog.entries).toEqual([]); expect(catalog.withdrawn).toHaveLength(1);
  expect(f.state().releases).toHaveLength(1); expect(f.state().audit.map((e: any) => e.action)).toEqual(['create', 'submit', 'approve', 'report', 'withdraw']);
});
it('blocks same-version byte rewrites and ownership transfer across upgrades and withdrawals', async () => {
  const f = setup(), first = await f.publish();
  await f.publish(first.bytes, { version: '2.0.0' });
  const changedPack = petManifest(); changedPack.animations.idle.frames[0]!.ms = 101;
  const changed = await f.create(pet(changedPack)); await f.upload(changed);
  expect(await (await f.review(changed.sid)).json()).toEqual({ error: 'workshop_version_rewritten' });
  forumUser = 43; const outsider = await f.create(first.bytes, { version: '3.0.0' }); await f.upload(outsider);
  expect(await (await f.review(outsider.sid)).json()).toEqual({ error: 'workshop_owner_conflict' });
  forumUser = 42;
  expect((await f.call(`${API}/submissions/${first.sid}/withdraw`, 'POST', { reason: 'Withdraw old version' })).status).toBe(200);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0]).toMatchObject({ version: '2.0.0', blockedVersions: ['1.0.0'] });
  const old = await f.create(first.bytes); await f.upload(old); expect(await (await f.review(old.sid)).json()).toEqual({ error: 'workshop_version_withdrawn' });
});
it('uses the same authority and kill switch for companion catalog/GET/HEAD/Range/ETag', async () => {
  const f = setup(), item = await f.publish(companion(), { kind: 'companion' });
  const path = assetUrl(item.meta), catalog = await f.call('/market/companions.json'), tag = catalog.headers.get('ETag')!;
  expect((await catalog.json() as any).entries[0].kind).toBe('companion');
  f.env.WORKSHOP_COMPANION_ENABLED = '0';
  for (const [url, method, headers] of [['/market/companions.json', 'GET', { 'If-None-Match': tag }], [path, 'GET', { Range: 'bytes=1-' }], [path, 'HEAD', {}]] as const) {
    const result = await f.call(url, method, undefined, false, headers); expect(result.status).toBe(503); expect(await result.json()).toEqual({ error: 'workshop_companion_disabled' });
  }
  const main = await (await f.call('/market/workshop.json')).json() as any; expect(main.entries).toEqual([]); expect(main.features.companion).toBe(false);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`, 'GET', undefined, true)).status).toBe(200);
});
it('returns stable failures for invalid/revoked forum keys without persisting or logging upstream text', async () => {
  const f = setup(), logged = vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.mocked(fetch).mockResolvedValueOnce(new Response('synthetic secret must not escape', { status: 403 }));
  const response = await f.call(API + '/submissions'); expect(response.status).toBe(401); expect(await response.json()).toEqual({ error: 'workshop_forum_auth_invalid' });
  vi.mocked(fetch).mockRejectedValueOnce(new Error('synthetic upstream credential failure'));
  const unavailable = await f.call(API + '/submissions'); expect(unavailable.status).toBe(503); expect(await unavailable.text()).not.toContain('credential');
  f.env.WORKSHOP_FORUM_URL = 'https://example.org/another/path';
  expect(await (await f.call(API + '/submissions')).json()).toEqual({ error: 'workshop_forum_configuration' });
  expect(logged).not.toHaveBeenCalled(); expect(f.bucket.objects.size).toBe(0);
});
it('charges invalid archive attempts and verifies both declared SHA and actual byte count', async () => {
  const f = setup(), item = await f.create();
  const wrong = Buffer.from(item.bytes); wrong[0] ^= 1;
  expect(await (await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', wrong)).json()).toEqual({ error: 'workshop_sha_mismatch' });
  expect(await (await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', wrong.subarray(1))).json()).toEqual({ error: 'workshop_size_mismatch' });
  expect(f.bucket.objects.has(blobKey(item.meta.sha256))).toBe(false); expect(f.state().submissions[0].status).toBe('draft');
  expect([...f.kv.values.values()]).toContain('2');
});
it('reports a CAS loser without losing the winning submission', async () => {
  const f = setup(), bytes = pet(), meta = metaFor(bytes);
  const responses = await Promise.all(['first', 'second'].map(request => f.call(API + '/submissions', 'POST', { ...meta, requestId: `concurrent_request_${request}` })));
  expect(responses.map(r => r.status).sort()).toEqual([201, 409]); expect(f.state().submissions).toHaveLength(1); expect(f.state().audit).toHaveLength(1);
});
it('cannot approve a concurrently withdrawn pending record even after its blob is validated', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  const put = f.bucket.put.bind(f.bucket);
  let release!: () => void, entered!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; }), started = new Promise<void>(resolve => { entered = resolve; });
  vi.spyOn(f.bucket, 'put').mockImplementation(async (key, bytes, options) => {
    if (key === STATE_KEY && new TextDecoder().decode(bytes as Uint8Array).includes('"status":"approved"')) { entered(); await gate; }
    return put(key, bytes, options);
  });
  const approving = f.review(item.sid); await started;
  expect((await f.call(`${API}/submissions/${item.sid}/withdraw`, 'POST', { reason: 'Cancel while in review' })).status).toBe(200);
  release(); expect(await (await approving).json()).toEqual({ error: 'workshop_state_conflict' });
  expect(f.state().releases).toEqual([]); expect((await f.call(assetUrl(item.meta))).status).toBe(404);
});
it('fails closed for corrupt durable authority and for changed actual blob metadata', async () => {
  const f = setup(), item = await f.publish();
  const object = f.bucket.objects.get(blobKey(item.meta.sha256))!; object.bytes = Buffer.from('different bytes');
  expect(await (await f.call(assetUrl(item.meta))).json()).toEqual({ error: 'workshop_storage_unavailable' });
  const state = f.state(); state.releases = [];
  f.bucket.objects.get(STATE_KEY)!.bytes = Buffer.from(JSON.stringify(state));
  expect(await (await f.call('/market/workshop.json')).json()).toEqual({ error: 'workshop_state_invalid' });
  expect((await f.call(assetUrl(item.meta), 'HEAD')).status).toBe(503);
});
it('keeps rejected submissions private and pages only the requesting owner records', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  expect((await f.review(item.sid, 'reject')).status).toBe(200);
  expect((await f.call(assetUrl(item.meta))).status).toBe(404);
  expect((await f.review(item.sid)).status).toBe(409);
  await f.create(); await f.create();
  const first = await (await f.call(API + '/submissions?limit=2')).json() as any;
  expect(first.submissions).toHaveLength(2); expect(first.nextCursor).toBeTruthy();
  const second = await (await f.call(API + '/submissions?limit=2&cursor=' + first.nextCursor)).json() as any;
  expect(second.submissions).toHaveLength(1); expect(second.nextCursor).toBe(null);
  forumUser = 43; expect((await (await f.call(API + '/submissions')).json() as any).submissions).toEqual([]);
  expect((await (await f.call(API + '/admin/submissions?status=rejected', 'GET', undefined, true)).json() as any).submissions).toHaveLength(1);
});
it('recovers an unknown successful CAS outcome by the same requestId without duplicating a submission', async () => {
  const f = setup(), put = f.bucket.put.bind(f.bucket), bytes = pet(), metadata = metaFor(bytes), requestId = 'unknown_outcome_request';
  let once = true;
  vi.spyOn(f.bucket, 'put').mockImplementation(async (key, value, options) => {
    const result = await put(key, value, options);
    if (key === STATE_KEY && once) { once = false; throw new Error('synthetic acknowledgement loss'); }
    return result;
  });
  const unknown = await f.call(API + '/submissions', 'POST', { ...metadata, requestId }); expect(unknown.status).toBe(503);
  const retry = await f.call(API + '/submissions', 'POST', { ...metadata, requestId }); expect(retry.status).toBe(200);
  expect(f.state().submissions).toHaveLength(1); expect(f.state().audit).toHaveLength(1);
});
it('lets moderators terminate abandoned drafts while retaining immutable metadata/audit', async () => {
  const f = setup(), item = await f.create();
  const path = `${API}/admin/submissions/${item.sid}/withdraw`;
  expect((await f.call(path, 'POST', { reason: 'Abandoned draft' })).status).toBe(401);
  const stopped = await f.call(path, 'POST', { reason: 'Abandoned draft' }, true);
  expect(stopped.status).toBe(200); expect((await stopped.json() as any).submission.status).toBe('withdrawn');
  expect(f.state().submissions).toHaveLength(1); expect(f.state().audit.at(-1)).toMatchObject({ action: 'withdraw', actor: 'admin' });
  expect((await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes)).status).toBe(409);
  expect((await f.call(path, 'POST', { reason: 'Repeat withdrawal' }, true)).status).toBe(200);
  expect(f.state().audit).toHaveLength(2);
});
