import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { packageFromPath, validateCatalog } from '../src/market';
import { makeEnv, makeCtx } from './fakes';
let counter = 0;
const entry = {
  version: '1.2.3',
  tier: 'community',
  title: { zh: '搜索', en: 'Search' },
  summary: { zh: '搜索网页', en: 'Search the web' },
  risk: { level: 'medium', flags: ['network', 'shell'] },
  integrity: 'sha512-' + 'A'.repeat(86) + '==',
  checkedAt: '2026-10-30T00:00:00Z',
  blockedVersions: [],
  dshGo: { adapted: false, features: [] },
  screenshots: [],
};
const docs = () => ({
  index: {
    format: 1,
    title: { en: 'DSH Go' },
    plugins: [{ name: '@scope/plugin', versions: [{ version: '1.2.3', source: { type: 'npm' } }] }],
  },
  sidecar: { schema: 1, generatedAt: '2026-10-30T00:00:00Z', plugins: { '@scope/plugin': structuredClone(entry) } },
});
function setup() {
  const env = makeEnv({ MARKET_SOURCE_URL: `https://example.com/market-${counter++}/` }),
    ctx = makeCtx();
  return { ...env, ...ctx };
}
const request = (path: string, method = 'GET', headers?: Record<string, string>) =>
  new Request('https://go.dshtui.com' + path, { method, headers });
function upstream(data = docs()) {
  return vi
    .spyOn(globalThis, 'fetch')
    .mockImplementation(async (input) =>
      Response.json(String(input).endsWith('index.json') ? data.index : data.sidecar),
    );
}
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});
describe('market routes', () => {
  it('does not extend browser freshness beyond the snapshot expiry', async () => {
    const c = setup();
    upstream();
    await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 540000);
    const r = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    expect(r.headers.get('cache-control')).toBe('public, max-age=60');
  });
  it('serves the format 1 and sidecar pair and caches for ten minutes', async () => {
    const c = setup(),
      f = upstream();
    const r = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    expect(r.status).toBe(200);
    expect((await r.json()).format).toBe(1);
    expect(r.headers.get('cache-control')).toContain('600');
    expect(r.headers.get('access-control-allow-origin')).toBe('*');
    expect(f).toHaveBeenCalledTimes(2);
    expect(f.mock.calls[0]![1]).toMatchObject({
      headers: { Accept: 'application/json', 'User-Agent': 'dshgo-share (+https://go.dshtui.com)' },
      redirect: 'manual',
    });
    const s = await worker.fetch(request('/market/dsh-go.json'), c.env, c.ctx);
    expect((await s.json()).schema).toBe(1);
    expect(f).toHaveBeenCalledTimes(2);
    expect(c.kv.values.size).toBe(1);
    expect([...c.kv.options.values()][0]).toBeUndefined();
  });
  it('retains last valid snapshot on upstream errors and rejects mismatched replacement', async () => {
    const c = setup();
    const f = upstream();
    await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 601000);
    f.mockRejectedValue(new Error('offline'));
    const r = await worker.fetch(request('/market/dsh-go.json'), c.env, c.ctx);
    expect(r.status).toBe(200);
    expect(r.headers.get('x-market-stale')).toBe('true');
    expect((await r.json()).plugins['@scope/plugin'].version).toBe('1.2.3');
    const bad = docs();
    bad.sidecar.plugins['@scope/plugin'].version = '9.0.0';
    f.mockImplementation(async (input) =>
      Response.json(String(input).endsWith('index.json') ? bad.index : bad.sidecar),
    );
    const again = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    expect(again.headers.get('x-market-stale')).toBe('true');
    expect([...c.kv.values.values()][0]).not.toContain('9.0.0');
  });
  it('reads a durable stale copy after an isolate starts and survives KV failure', async () => {
    const c = setup(),
      d = docs();
    await c.kv.put(
      'market:v1:' + c.env.MARKET_SOURCE_URL,
      JSON.stringify({ at: Date.now() - 700000, index: JSON.stringify(d.index), sidecar: JSON.stringify(d.sidecar) }),
    );
    const f = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('offline'));
    const r = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    expect(r.status).toBe(200);
    expect(r.headers.get('x-market-stale')).toBe('true');
    f.mockImplementation(async (input) => Response.json(String(input).endsWith('index.json') ? d.index : d.sidecar));
    c.kv.failWrites = true;
    expect((await worker.fetch(request('/market/index.json'), c.env, c.ctx)).status).toBe(200);
    c.kv.failReads = true;
    f.mockRejectedValue(new Error('offline'));
    expect((await worker.fetch(request('/market/index.json'), c.env, c.ctx)).status).toBe(200);
  });
  it('fails closed without a valid cache, including invalid JSON and oversized upstream', async () => {
    for (const response of [
      new Response('bad', { status: 503 }),
      new Response(null, { status: 302, headers: { Location: 'https://other.example/catalog' } }),
      new Response('not json'),
      new Response('{}', { headers: { 'content-length': '99999999' } }),
    ]) {
      const c = setup();
      vi.spyOn(globalThis, 'fetch').mockImplementation(async () => response.clone());
      const r = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
      expect(r.status).toBe(503);
      expect(r.headers.get('cache-control')).toBe('no-store');
      vi.restoreAllMocks();
    }
  });
  it('logs only bounded failure metadata without upstream content or exception messages', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const f = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('secret body', { status: 403 }));
    let c = setup();
    expect((await worker.fetch(request('/market/index.json'), c.env, c.ctx)).status).toBe(503);
    expect(log).toHaveBeenLastCalledWith('market refresh failed', 'upstream-http', 403);
    f.mockRejectedValue(new TypeError('secret URL or credentials'));
    c = setup();
    expect((await worker.fetch(request('/market/index.json'), c.env, c.ctx)).status).toBe(503);
    expect(log).toHaveBeenLastCalledWith('market refresh failed', 'TypeError', null);
    expect(JSON.stringify(log.mock.calls)).not.toContain('secret');
  });
  it('renders escaped localized cards, risks, canonical app link and download fallback', async () => {
    const c = setup(),
      d = docs();
    d.sidecar.plugins['@scope/plugin'].title.zh = '<script>alert(1)</script>';
    upstream(d);
    const r = await worker.fetch(request('/p/%40scope%2Fplugin'), c.env, c.ctx),
      html = await r.text();
    expect(r.status).toBe(200);
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toContain('<script>');
    expect(html).toContain('执行命令');
    expect(html).toContain('dshgo://go.dshtui.com/p/%40scope%2Fplugin');
    expect(html).toContain('href="/download"');
    expect(r.headers.get('content-security-policy')).toContain("frame-ancestors 'none'");
    const en = await worker.fetch(request('/p/@scope/plugin', 'GET', { 'Accept-Language': 'en-US' }), c.env, c.ctx);
    expect(await en.text()).toContain('Search the web');
    expect(en.headers.get('vary')).toBe('Accept-Language');
    const head = await worker.fetch(request('/p/@scope/plugin', 'HEAD'), c.env, c.ctx);
    expect(head.status).toBe(200);
    expect(await head.text()).toBe('');
  });
  it('rejects unknown paths and methods without fetching and returns absent package 404', async () => {
    const c = setup(),
      f = upstream();
    for (const p of ['/market/other.json', '/p/', '/p/%ZZ', '/p/%252Fbad', '/p/UPPER'])
      expect((await worker.fetch(request(p), c.env, c.ctx)).status).toBe(404);
    expect((await worker.fetch(request('/market/index.json', 'POST'), c.env, c.ctx)).status).toBe(405);
    expect(f).not.toHaveBeenCalled();
    expect((await worker.fetch(request('/p/absent'), c.env, c.ctx)).status).toBe(404);
  });
  it('validates package identity, audit shape and paired pinned versions', () => {
    expect(packageFromPath('/p/%40scope%2Fplugin')).toBe('@scope/plugin');
    expect(packageFromPath('/p/plain-plugin')).toBe('plain-plugin');
    const d = docs();
    expect(validateCatalog(d.index, d.sidecar)).toBe(true);
    d.index.plugins.push(d.index.plugins[0]!);
    expect(validateCatalog(d.index, d.sidecar)).toBe(false);
    const e = docs();
    e.sidecar.plugins['@scope/plugin'].integrity = 'tampered';
    expect(validateCatalog(e.index, e.sidecar)).toBe(false);
  });
});
describe('market cron', () => {
  const scheduled = (c: ReturnType<typeof setup>) => worker.scheduled({} as ScheduledController, c.env, c.ctx);
  const text = (c: ReturnType<typeof setup>, key: string) => new TextDecoder().decode(c.dl.objects.get(key)!.bytes);
  it('puts a valid catalog on the public bucket, the same the routes serve', async () => {
    const c = setup(),
      f = upstream();
    await scheduled(c);
    for (const key of ['market/index.json', 'market/dsh-go.json']) {
      expect(c.dl.objects.get(key)).toMatchObject({ contentType: 'application/json; charset=utf-8', cacheControl: 'public, max-age=300' });
    }
    expect(JSON.parse(text(c, 'market/index.json'))).toEqual(docs().index);
    expect(JSON.parse(text(c, 'market/dsh-go.json'))).toEqual(docs().sidecar);
    const r = await worker.fetch(request('/market/index.json'), c.env, c.ctx);
    expect(await r.text()).toBe(text(c, 'market/index.json'));
    expect(f).toHaveBeenCalledTimes(2);
  });
  it('leaves the files as they were when the fetch fails or the catalog is invalid', async () => {
    const c = setup(),
      f = upstream();
    await scheduled(c);
    const before = structuredClone([...c.dl.objects]);
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const bad = docs();
    bad.sidecar.plugins['@scope/plugin'].version = '9.0.0';
    f.mockImplementation(async (input) => Response.json(String(input).endsWith('index.json') ? bad.index : bad.sidecar));
    await scheduled(c);
    expect(log).toHaveBeenLastCalledWith('market publish failed', 'invalid-catalog', null);
    f.mockResolvedValue(new Response('down', { status: 503 }));
    await scheduled(c);
    expect(log).toHaveBeenLastCalledWith('market publish failed', 'upstream-http', 503);
    f.mockRejectedValue(new TypeError('offline'));
    await scheduled(c);
    expect([...c.dl.objects]).toEqual(before);
    expect(JSON.stringify([...c.kv.values.values()])).not.toContain('9.0.0');
  });
});
