// Volatile bridge state. The phone owns settings and resynchronizes after the
// advertised instanceId changes; runtime snapshots themselves are engine-owned.
import { createHash, randomUUID } from 'node:crypto';
import { CompanionError, invalid } from './schema.js';
import { validRecallSessionId } from './recall-schema.js';

export const FULL_PRESET = 'dsh-go-companion-full';
const MAX_SESSIONS = 128, MAX_PENDING = 32, RECENT_MS = 30 * 60 * 1000;
const kinds = new Set(['pet', 'feed', 'task-finished', 'renamed']);
const controls = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const fields = (v, required, optional = []) => record(v)
  && required.every(k => Object.hasOwn(v, k)) && Object.keys(v).every(k => [...required, ...optional].includes(k));
const text = (v, max) => typeof v === 'string' && [...v].length <= max && !controls.test(v);
export const contextId = v => text(v, 128) && v.length > 0 && !/[\r\n\t]/.test(v);
const time = v => Number.isSafeInteger(v) && v >= 0 && v <= 8640000000000000;
export const contextJson = v => JSON.stringify(v).replaceAll('<', '\\u003c').replaceAll('>', '\\u003e').replaceAll('&', '\\u0026');

function profileOf(value) {
  const limits = { persona: 4000, name: 24, callMe: 40, moves: 1024 };
  if (!fields(value, Object.keys(limits))) throw invalid();
  const result = {};
  for (const [key, limit] of Object.entries(limits)) {
    if (!text(value[key], limit) || (['name', 'callMe'].includes(key) && /[\r\n\t]/.test(value[key]))) throw invalid();
    result[key] = value[key].trim();
  }
  return Object.freeze(result);
}

export function validatePromptContext(value) {
  if (!fields(value, ['v', 'sessionId', 'requestId', 'instanceId', 'events'],
    ['profile', 'expectedProfileRevision', 'query']) || value.v !== 1 ||
    !contextId(value.sessionId) || !contextId(value.requestId) || !contextId(value.instanceId) ||
    !Array.isArray(value.events) || value.events.length > 8 ||
    (value.query !== undefined && !text(value.query, 256))) throw invalid();
  const out = { v: 1, sessionId: value.sessionId, requestId: value.requestId, instanceId: value.instanceId };
  if (Object.hasOwn(value, 'profile') !== Object.hasOwn(value, 'expectedProfileRevision')) throw invalid();
  if (Object.hasOwn(value, 'profile')) {
    if (!Number.isSafeInteger(value.expectedProfileRevision) || value.expectedProfileRevision < 0) throw invalid();
    out.profile = profileOf(value.profile);
    out.expectedProfileRevision = value.expectedProfileRevision;
  }
  const ids = new Set();
  out.events = value.events.map(e => {
    if (!fields(e, ['id', 'kind', 'at'], ['detail']) || !contextId(e.id) || !kinds.has(e.kind) ||
      !time(e.at) || (e.detail !== undefined && !text(e.detail, 160)) || ids.has(e.id)) throw invalid();
    ids.add(e.id);
    return Object.freeze({ id: e.id, kind: e.kind, at: e.at, ...(e.detail ? { detail: e.detail } : {}) });
  });
  if (value.query !== undefined) out.query = value.query;
  return out;
}

// Internal callers pass the actual Agent/Session objects, never just a reused
// sessionId. A ticket fences a query that was already awaiting storage at bind.
export function createCompanionPromptContext({ now = Date.now, instanceId = randomUUID(),
  isCurrent = () => true, allowMemory = () => true } = {}) {
  const sessions = new Map(), tickets = new WeakMap(), disabledSessions = new WeakSet();
  let closed = false, highWater = 0;
  const available = () => {
    if (closed) throw new CompanionError(503, 'unavailable', 'Companion context instance was disposed');
  };
  const at = () => {
    available();
    const value = now();
    if (!time(value)) throw new CompanionError(503, 'unavailable', 'Companion clock is unavailable');
    highWater = Math.max(highWater, value);
    return value;
  };
  const changed = () => new CompanionError(409, 'session-unavailable', 'Companion session changed; synchronize again');
  const live = agent => validRecallSessionId(agent?.id) && agent.session?.id === agent.id && isCurrent(agent) === true;
  const lookup = agent => {
    if (closed || !live(agent)) return undefined;
    const value = sessions.get(agent.id);
    return value?.agent === agent && value.session === agent.session ? value : undefined;
  };
  function invalidate(value, disable = false) {
    if (value.memoryEpoch === Number.MAX_SAFE_INTEGER) {
      value.memoryDisabled = true;
    } else value.memoryEpoch++;
    value.memoryDisabled ||= disable;
    value.memories = [];
    for (const lease of [...value.pending.values(), ...value.parked.values()]) {
      lease.memories = [];
      lease.memoryEpoch = value.memoryEpoch;
    }
  }
  function refreshMemory(value) {
    let allowed = false;
    try { allowed = allowMemory(value.agent) === true; } catch { /* fail closed for memory only */ }
    if (!value.memoryDisabled && (!allowed || disabledSessions.has(value.session))) invalidate(value, true);
  }
  function open(agent) {
    available();
    if (!live(agent)) throw changed();
    let value = lookup(agent);
    if (!value) {
      if (!sessions.has(agent.id) && sessions.size >= MAX_SESSIONS) {
        throw new CompanionError(409, 'limit-reached', 'Companion context session limit reached');
      }
      // Reusing the id never copies leases, receipts or profile from an old
      // actual Agent/Session. A late callback cannot open or replace a state.
      value = { agent, session: agent.session, profile: undefined, revision: 0,
        pending: new Map(), parked: new Map(), receipts: new Map(), seen: new Set(),
        turn: undefined, events: [], memories: [], memoryEpoch: 0, memoryDisabled: false,
        currentMemoryEpoch: 0, lastHumanAt: undefined, idleMinutes: undefined };
      for (let seq = (agent.session.seq ?? 0) - 1; seq >= 0; seq--) {
        const event = agent.session.eventAt(seq);
        if (event?.type === 'user/message' && owner(event.data) && time(event.time)) {
          value.lastHumanAt = event.time; break;
        }
      }
      sessions.set(agent.id, value);
    }
    refreshMemory(value);
    return value;
  }
  const owner = message => message?.source?.kind === 'user' && message.source.principal === undefined;
  const expired = lease => highWater - lease.at > RECENT_MS;
  function prune(value) {
    for (const map of [value.pending, value.parked]) {
      for (const [id, lease] of map) if (expired(lease)) map.delete(id);
    }
    // A discarded Inbox occurrence is a parked lease, not a cancellation.
    // Parked requests do not occupy the 32 active preparation slots.
    while (value.parked.size > 64) value.parked.delete(value.parked.keys().next().value);
    for (const id of value.receipts.keys()) {
      if (value.receipts.size <= 128) break;
      if (!value.pending.has(id) && !value.parked.has(id)) value.receipts.delete(id);
    }
    while (value.seen.size > 256) value.seen.delete(value.seen.values().next().value);
  }
  const describe = value => ({ v: 1, supported: true, instanceId, sessionId: value.agent.id,
    profileRevision: value.revision, persistence: 'connection', requestBinding: 'rpcId',
    maxEvents: 8, maxPersonaCodePoints: 4000,
    memoryMode: value.memoryDisabled ? 'automatic' : 'query', memoryEpoch: value.memoryEpoch });
  function capture(agent) {
    const value = open(agent);
    const token = Object.freeze({ allowed: !value.memoryDisabled });
    tickets.set(token, { value, epoch: value.memoryEpoch });
    return token;
  }
  return {
    info(agent) { at(); return describe(open(agent)); },
    profile(agent) { return lookup(agent)?.profile; },
    captureMemory: capture,
    // Called synchronously inside recall's serial bind, before publishing a
    // marker/ready. Even a later failed bind cannot restore an old query result.
    disableMemory(agent) {
      available();
      if (!live(agent)) throw changed();
      // A recall-only session must not consume a profile/sidecar slot, nor
      // inherit this endpoint's narrower 128-codepoint wire ID limit.
      disabledSessions.add(agent.session);
      const value = lookup(agent);
      if (value) invalidate(value, true);
    },
    retireMemory(agent) {
      const value = sessions.get(agent?.id);
      if (value?.agent === agent) { disabledSessions.add(value.session); invalidate(value, true); }
    },
    invalidateMemories() {
      if (closed) return;
      for (const value of sessions.values()) invalidate(value);
    },
    prepare(agent, input, memories = [], lastHumanAt, memoryTicket) {
      const value = validatePromptContext(input);
      if (value.instanceId !== instanceId) throw new CompanionError(409, 'context-restarted', 'Reload companion context capability');
      at();
      const ticket = tickets.get(memoryTicket ?? capture(agent));
      const current = lookup(agent);
      if (!ticket || ticket.value !== current || value.sessionId !== agent.id) throw changed();
      refreshMemory(current);
      prune(current);
      const digest = createHash('sha256').update(JSON.stringify(value)).digest('hex');
      const receipt = current.receipts.get(value.requestId);
      if (receipt && receipt.digest !== digest) {
        throw new CompanionError(409, 'request-conflict', 'Request id already has different companion context');
      }
      if (receipt && !receipt.committed && expired(receipt)) {
        throw new CompanionError(409, 'request-expired', 'Companion request lease expired; prepare a new request');
      }
      if (!receipt && value.profile && current.revision !== value.expectedProfileRevision) {
        throw new CompanionError(409, 'profile-conflict', 'Reload companion profile revision');
      }
      let lease = current.pending.get(value.requestId) ?? current.parked.get(value.requestId);
      if (!lease && !receipt?.committed) {
        if (current.pending.size >= MAX_PENDING) throw new CompanionError(409, 'limit-reached', 'Too many pending companion contexts');
        lease = { at: receipt?.at ?? highWater, events: value.events,
          memories: !current.memoryDisabled && ticket.epoch === current.memoryEpoch
            ? structuredClone(memories) : [], memoryEpoch: current.memoryEpoch };
        current.pending.set(value.requestId, lease);
      }
      // A retry reuses its original lease/expiry and never reapplies a profile
      // that has since changed. It can reconstruct an evicted parked lease.
      if (!receipt) {
        if (value.profile && JSON.stringify(value.profile) !== JSON.stringify(current.profile)) {
          if (current.revision === Number.MAX_SAFE_INTEGER) {
            current.pending.delete(value.requestId);
            throw new CompanionError(503, 'unavailable', 'Companion revision limit reached');
          }
          current.profile = value.profile; current.revision++;
        }
        current.receipts.set(value.requestId, { digest, at: highWater, committed: false });
      }
      if (time(lastHumanAt) && (current.lastHumanAt === undefined || lastHumanAt > current.lastHumanAt)) {
        current.lastHumanAt = lastHumanAt;
      }
      prune(current);
      return { ...describe(current), ...(value.profile ? {
        profileAccepted: JSON.stringify(current.profile) === JSON.stringify(value.profile) } : {}) };
    },
    claim(agent, message, turn) {
      if (!owner(message)) return;
      const current = lookup(agent);
      if (!current) return;
      const clock = at();
      refreshMemory(current); prune(current);
      if (current.turn !== turn) {
        current.turn = turn; current.events = []; current.memories = [];
      }
      // Recompute for EVERY owner human claim, including a same-turn steer
      // with no sidecar. A short or negative gap explicitly clears old idle.
      const gap = current.lastHumanAt === undefined ? undefined : clock - current.lastHumanAt;
      current.idleMinutes = gap !== undefined && gap >= RECENT_MS ? Math.floor(gap / 60000) : undefined;
      current.memories = [];
      current.currentMemoryEpoch = current.memoryEpoch;
      // A human claim can originate outside the RPC transport. It still
      // refreshes temporal/current-query state, but cannot claim a lease.
      if (!contextId(message.source.rpcId)) return;
      const pending = current.pending.get(message.source.rpcId) ?? current.parked.get(message.source.rpcId);
      if (!pending) return;
      for (const event of pending.events) {
        if (clock < event.at || highWater - event.at > RECENT_MS || current.seen.has(event.id) ||
          current.events.some(e => e.id === event.id)) continue;
        current.events.push(event);
      }
      current.events = current.events.slice(-8);
      if (!current.memoryDisabled && pending.memoryEpoch === current.memoryEpoch) current.memories = pending.memories;
    },
    commit(session, message, committedAt) {
      if (closed || !owner(message)) return;
      const current = sessions.get(session?.id);
      if (!current || current.session !== session || lookup(current.agent) !== current) return;
      if (time(committedAt)) current.lastHumanAt = committedAt;
      const requestId = message.source.rpcId;
      const pending = current.pending.get(requestId) ?? current.parked.get(requestId);
      if (pending) for (const event of pending.events) current.seen.add(event.id);
      const receipt = current.receipts.get(requestId);
      if (receipt) receipt.committed = true;
      current.pending.delete(requestId); current.parked.delete(requestId);
      at(); prune(current);
    },
    discard(agent, message) {
      if (!owner(message) || !contextId(message.source.rpcId)) return;
      const current = lookup(agent);
      if (!current) return;
      at(); prune(current);
      const id = message.source.rpcId, pending = current.pending.get(id);
      if (pending) {
        current.pending.delete(id); current.parked.set(id, pending);
        prune(current);
      }
    },
    end(session) {
      if (closed) return;
      const current = sessions.get(session?.id);
      if (current?.session === session) {
        current.turn = undefined; current.events = []; current.memories = []; current.idleMinutes = undefined;
      }
    },
    retire(agent) {
      const current = sessions.get(agent?.id);
      if (current?.agent === agent) {
        invalidate(current, true);
        sessions.delete(agent.id);
      }
    },
    render(agent) {
      const current = lookup(agent);
      if (!current) return '';
      const clock = at();
      refreshMemory(current); prune(current);
      const events = current.events.filter(e => clock >= e.at && highWater - e.at <= RECENT_MS);
      const memories = current.memoryDisabled || current.currentMemoryEpoch !== current.memoryEpoch ? []
        : current.memories.filter(m => m.expiresAt === null || m.expiresAt > highWater).map(m => m.text);
      if (!events.length && !memories.length && current.idleMinutes === undefined) return '';
      return `<companion_context>${contextJson({ ...(events.length ? { events } : {}),
        ...(memories.length ? { memories } : {}),
        ...(current.idleMinutes === undefined ? {} : { idleSinceHumanMinutes: current.idleMinutes }) })}</companion_context>`;
    },
    clear() { closed = true; sessions.clear(); },
  };
}
