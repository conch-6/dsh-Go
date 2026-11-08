import { CompanionError, MAX_BODY_BYTES, invalid, ioError } from "./schema.js";
import { createCompanionStore } from "./store.js";

const ROOT = "/dsh-go/v1/companion";

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const cleanup = () => {
      req.off("data", data);
      req.off("end", end);
      req.off("error", fail);
      req.off("aborted", abort);
    };
    const fail = () => { cleanup(); reject(invalid()); };
    const abort = () => {
      cleanup();
      // IncomingMessage emits ECONNRESET after 'aborted'; keep that expected error handled.
      req.once("error", () => {});
      reject(invalid());
    };
    const data = (chunk) => {
      size += chunk.length;
      if (size <= MAX_BODY_BYTES) chunks.push(chunk);
    };
    const end = () => {
      cleanup();
      if (size > MAX_BODY_BYTES) return reject(new CompanionError(413, "too-large", "Companion request body is too large"));
      try { resolve(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)))); }
      catch { reject(invalid()); }
    };
    if (req.aborted || req.destroyed) return reject(invalid());
    req.on("data", data);
    req.on("end", end);
    req.on("error", fail);
    req.on("aborted", abort);
  });
}

// Called only after the bridge's existing connection.requestRejection guard.
// Store construction does no I/O, including on hosts that never open this page.
export function createCompanionRoutes({ send, store = createCompanionStore() }) {
  const routes = new Map([
    [ROOT, { method: "GET", run: () => store.getSnapshot() }],
    [`${ROOT}/events`, { method: "POST", run: (body) => store.event(body) }],
    [`${ROOT}/memories/delete`, { method: "POST", run: (body) => store.deleteMemory(body) }],
    [`${ROOT}/memories/clear`, { method: "POST", run: (body) => store.clearMemories(body) }],
    [`${ROOT}/context`, { method: "POST", run: (body) => store.getContext(body) }],
    [`${ROOT}/export`, { method: "GET", run: () => store.exportData() }],
  ]);
  return {
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(`${ROOT}/`)) return false;
      try {
        const route = path === `${ROOT}/memories`
          ? (req.method === "GET" ? { method: "GET", run: () => store.getMemories() }
            : { method: "POST", run: (body) => store.upsertMemory(body) })
          : routes.get(path);
        if (route === undefined) {
          req.resume();
          throw new CompanionError(404, "not-found", "Companion route not found");
        }
        if (req.method !== route.method) {
          req.resume();
          throw new CompanionError(405, "invalid-request", "Method not allowed");
        }
        let body;
        if (route.method === "POST") {
          if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
            req.resume();
            throw new CompanionError(415, "content-type", "Content-Type must be application/json");
          }
          body = await readJson(req);
        } else {
          req.resume();
        }
        const result = await route.run(body);
        if (!res.destroyed) send(res, 200, result);
      } catch (error) {
        const failure = error instanceof CompanionError ? error : ioError();
        if (!res.destroyed) send(res, failure.status, { error: { code: failure.code, message: failure.message } });
      }
      return true;
    },
  };
}
