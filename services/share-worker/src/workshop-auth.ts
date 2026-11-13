import type { Env } from './env';
import { readCapped } from './api';
import { record } from './pet-catalog';
import { readBounded } from './pet-market-io';
import { burstAllowed, clientKey, uploadQuota } from './limits';
import { strictJson } from './workshop-archive';
import { requireWorkshop as need, sha256, text, whole, WorkshopError, type WorkshopKind } from './workshop-common';
import type { Owner } from './workshop-state';

export function features(env: Env) { return { uploads: env.WORKSHOP_UPLOAD_ENABLED === undefined || env.WORKSHOP_UPLOAD_ENABLED === '1', companion: env.WORKSHOP_COMPANION_ENABLED === undefined || env.WORKSHOP_COMPANION_ENABLED === '1' }; }
export function enabled(env: Env, kind?: WorkshopKind): void {
  need(features(env).uploads, 'upload_disabled', 503);
  if (kind === 'companion') need(features(env).companion, 'companion_disabled', 503);
}
export function forumOrigin(env: Env): string {
  try {
    const value = env.WORKSHOP_FORUM_URL ?? 'https://forum.dshtui.com', url = new URL(value);
    need(url.protocol === 'https:' && url.origin.length <= 2048 && !url.username && !url.password && url.pathname === '/' && !url.search && !url.hash, 'forum_configuration', 503);
    return url.origin;
  } catch { throw new WorkshopError('forum_configuration', 503); }
}
export async function user(request: Request, env: Env): Promise<Owner> {
  const key = request.headers.get('User-Api-Key');
  need(key && key.length <= 512 && /^[\x21-\x7e]+$/.test(key), 'forum_auth_required', 401);
  const origin = forumOrigin(env);
  // This is an assertion about the configured destination, never an upstream URL.
  need(request.headers.get('X-Workshop-Forum-Origin') === origin, 'forum_origin', 409);
  await limitBurst(request, env, false);
  try {
    // Do not forward a client-selected origin, cookies, Authorization, or
    // User-Api-Client-Id: Discourse can mutate client binding from that header.
    // Workers supports manual/follow, not error. Manual plus the strict200
    // check below prevents any redirect carrying the key to another origin.
    const response = await fetch(origin + '/session/current.json', {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(15_000),
      headers: { 'User-Api-Key': key, Accept: 'application/json' },
    });
    if (response.status === 401 || response.status === 403 || response.status === 404) {
      void response.body?.cancel().catch(() => {}); throw new WorkshopError('forum_auth_invalid', 401);
    }
    if (response.status !== 200 || !response.body) { void response.body?.cancel().catch(() => {}); throw new WorkshopError('forum_unavailable', 503); }
    const length = response.headers.get('Content-Length');
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > 65536)) { void response.body.cancel().catch(() => {}); throw new WorkshopError('forum_unavailable', 503); }
    const value = strictJson(await readBounded(response.body, 65536), 65536, 32);
    need(record(value) && record(value.current_user) && whole(value.current_user.id, 1, Number.MAX_SAFE_INTEGER) && text(value.current_user.username, 256), 'forum_auth_invalid', 401);
    return { forumOrigin: origin, forumUserId: value.current_user.id, username: value.current_user.username };
  } catch (error) {
    if (error instanceof WorkshopError && ['forum_auth_invalid', 'forum_unavailable'].includes(error.code)) throw error;
    throw new WorkshopError('forum_unavailable', 503);
  }
}
export async function admin(request: Request, env: Env): Promise<void> {
  // Same floor as the share API's admin path: a short key is a misconfiguration, not a credential.
  need(env.ADMIN_KEY && env.ADMIN_KEY.length >= 32, 'admin_unavailable', 503);
  const provided = request.headers.get('X-Admin-Key'); need(provided && provided.length <= 4096, 'admin_auth_required', 401);
  const [a, b] = await Promise.all([sha256(provided), sha256(env.ADMIN_KEY)]);
  let different = 0; for (let n = 0; n < a.length; n++) different |= a.charCodeAt(n) ^ b.charCodeAt(n);
  need(different === 0, 'admin_auth_required', 401);
}
/// [scope] gives a kind of request its own count per client, so a page of
/// pictures cannot use up what the catalog and package downloads need.
export async function limitBurst(request: Request, env: Env, write: boolean, scope = 'workshop'): Promise<void> {
  need(await burstAllowed(write ? env.UPLOAD_BURST : env.READ_LIMIT, `${scope}:${clientKey(request)}`), 'rate_limited', 429);
}
export async function quota(request: Request, env: Env, owner: Owner, action: string, count: number): Promise<void> {
  await limitBurst(request, env, true);
  const meter = await uploadQuota({ ...env, UPLOADS_PER_HOUR: String(count) }, `workshop:${owner.forumOrigin}:${owner.forumUserId}:${action}`);
  if (!meter.allowed) throw new WorkshopError('rate_limited', 429, { 'Retry-After': String(meter.retryAfter) });
  // Charge the attempt before archive parsing, including malformed packages.
  // KV remains an approximate cross-colo limit, as in the existing service.
  await meter.commit();
}
export async function jsonBody(request: Request): Promise<Record<string, unknown>> {
  need(request.headers.get('Content-Type')?.split(';')[0]?.trim().toLowerCase() === 'application/json', 'content_type', 415);
  const bytes = await readCapped(request, 16384); need(bytes, 'body_too_large', 413);
  try { const value = strictJson(bytes, 16384, 16); need(record(value), 'bad_request'); return value; }
  catch { throw new WorkshopError('bad_request'); }
}
