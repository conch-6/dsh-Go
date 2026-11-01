// No filesystem access here: only the bundled engine's fenced lifecycle seam may delete.
const ROOT = "/dsh-go/v1/sessions";
const STATUS = { "session-active": 409, "session-related": 409, "writer-held": 409,
  "not-found": 404, unavailable: 503, failed: 500 };
const errorBody = (code, message) => ({ error: { code, message } });

export function sessionDeletionUnavailable(req) {
  try {
    const path = new URL(req.url ?? "/", "http://dsh-go.invalid").pathname;
    if (path === `${ROOT}/deletion` || path === `${ROOT}/delete`)
      return errorBody("unavailable", "Safe session deletion is unavailable.");
  } catch {}
}

export function createSessionDeletion(ctx, { readBody, send }) {
  const seam = async () => {
    const persistence = ctx.get("sessionPersistence");
    const lifecycle = ctx.get("agentLoop");
    const cache = ctx.get("sessionProjectionCache");
    const query = ctx.get("sessionQuery");
    const schedule = ctx.get("schedule");
    const workspace = ctx.get("workspaceRegistry");
    if (persistence?.dshGoDeletion?.version !== 1 || lifecycle?.dshGoDeletionVersion !== 1
      || cache?.dshGoDeletionVersion !== 1 || query?.dshGoDeletionVersion !== 1
      || schedule?.dshGoDeletionVersion !== 1 || workspace?.dshGoDeletionVersion !== 1) return;
    if (process.platform === "win32") return;
    try { if (!await schedule.dshGoCanDelete()) return; } catch { return; }
    return { persistence, lifecycle, cache, query, schedule, workspace };
  };
  return {
    async handle(req, res, path) {
      if (path !== `${ROOT}/deletion` && path !== `${ROOT}/delete`) return false;
      if (path === `${ROOT}/deletion`) {
        if (req.method !== "GET") send(res, 405, errorBody("unavailable", "Use GET."));
        else send(res, 200, { supported: await seam() !== undefined, version: 1 });
        return true;
      }
      if (req.method !== "POST") {
        req.resume();
        send(res, 405, errorBody("unavailable", "Use POST."));
        return true;
      }
      const services = await seam();
      if (services === undefined) {
        req.resume();
        send(res, 503, errorBody("unavailable", "Safe session deletion is not installed on this host."));
        return true;
      }
      if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
        req.resume();
        send(res, 415, errorBody("failed", "Content-Type must be application/json."));
        return true;
      }
      let id;
      try {
        const body = JSON.parse((await readBody(req, 4096)).toString("utf8"));
        if (body === null || typeof body !== "object" || Array.isArray(body)
          || Object.keys(body).length !== 1 || typeof body.sessionId !== "string"
          || body.sessionId.length === 0 || body.sessionId.length > 256
          || /[\u0000-\u001f\u007f]/.test(body.sessionId)) throw new Error("Invalid sessionId.");
        id = body.sessionId;
      } catch (error) {
        send(res, error?.status === 413 ? 413 : 400, errorBody("failed", "Expected {sessionId: string}."));
        return true;
      }
      try {
        await services.persistence.dshGoDeletion.delete(id, {
          prepare: async () => {
            const activity = await ctx.waterfall("workspace/session-activity", { sessionId: id }, () => Promise.resolve([]));
            if (activity.length) throw Object.assign(new Error("Session has active work."), { code: "session-active" });
            await services.lifecycle.dshGoDisposeForDeletion(id);
          },
          inspectTasks: () => services.schedule.dshGoInspectDeletion(id),
          cleanup: async () => {
            await services.cache.dshGoForget(id);
            await services.query.dshGoForget(id);
            await services.workspace.dshGoForget(id);
          },
        });
        send(res, 200, { deleted: true, sessionId: id });
      } catch (error) {
        const code = Object.hasOwn(STATUS, error?.code) ? error.code
          : error?.name === "SessionAlreadyOwnedError" ? "writer-held" : "failed";
        // Never send filesystem paths, transcript fragments, or engine stacks to clients.
        const messages = { "session-active": "Session has active work.", "session-related": "Session has related agents or reminders.",
          "writer-held": "Session is owned by another writer. Try again after it closes.", "not-found": "Session was not found.",
          unavailable: "Safe session deletion is unavailable.", failed: "Session deletion failed. Retry to finish cleanup." };
        ctx.logger?.warn?.(`session deletion: ${code}`);
        send(res, STATUS[code], errorBody(code, messages[code]));
      }
      return true;
    },
  };
}
