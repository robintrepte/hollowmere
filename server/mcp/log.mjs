// Structured logs for hollowmere-mcp: one JSON object per line,
//   {"ts":"2026-11-02T10:00:00.000Z","level":"info","msg":"...", ...context}
// info goes to stdout, warn/error to stderr (PM2 keeps both, `pm2 logs hollowmere-mcp`).
// Context values are plain data chosen by the caller; never pass secrets, signatures, tokens or
// request bodies. Fields named like a secret are dropped as a last line of defence.
const LEVELS = new Set(["info", "warn", "error"]);
const SECRETISH = /secret|signature|token|password|authorization|http_key|body/i;

/** Clips strings and drops secret-looking fields; nested objects stay shallow (one level). */
export function cleanContext(ctx) {
  const out = {};
  for (const [k, v] of Object.entries(ctx || {})) {
    if (v === undefined || SECRETISH.test(k) || ["ts", "level", "msg"].includes(k)) continue;
    if (typeof v === "string") out[k] = v.length > 200 ? v.slice(0, 200) + "…" : v;
    else if (v === null || typeof v === "number" || typeof v === "boolean") out[k] = v;
    else if (v instanceof Error) out[k] = String(v.message || v).slice(0, 200);
    else { try { out[k] = JSON.parse(JSON.stringify(v, (key, x) => (key && SECRETISH.test(key) ? undefined : x))); } catch { out[k] = String(v); } }
  }
  return out;
}

export function makeLogger({ out = (line) => process.stdout.write(line + "\n"), err = (line) => process.stderr.write(line + "\n"), now = () => new Date() } = {}) {
  const emit = (level, msg, ctx) => {
    if (!LEVELS.has(level)) level = "info";
    const line = JSON.stringify({ ts: now().toISOString(), level, msg: String(msg), ...cleanContext(ctx) });
    (level === "info" ? out : err)(line);
  };
  return {
    info: (msg, ctx) => emit("info", msg, ctx),
    warn: (msg, ctx) => emit("warn", msg, ctx),
    error: (msg, ctx) => emit("error", msg, ctx),
  };
}

export const log = makeLogger();
