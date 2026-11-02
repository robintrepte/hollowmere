// Tretu platform webhook for Hollowmere: POST /api/tretu/webhook (contract §3 signature, §4 events).
// Served by the hollowmere-mcp process (PM2), proxied by nginx on hollowmere.tretu.de.
//
// Off unless TRETU_APP_SECRET is set for hollowmere-mcp (server/.env): it must equal the
// hollowmere secret in TRETU_APPS_JSON on tretu.de (and TRETU_APP_SECRET in Nakama's runtime env).
//
//   user.deleted -> Nakama RPC tretu_user_deleted {sub, mergedInto?}   (deletes or merges the farm)
//   user.updated -> Nakama RPC tretu_user_updated {sub, data}           (linked ids, username)
//   anything else -> 204
import crypto from "node:crypto";

export const MAX_BODY_BYTES = 64 * 1024;
export const MAX_SKEW_SEC = 300;
const SUB = /^[\w.-]{1,100}$/;

const sha256hex = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

/** `v1=` + hex HMAC-SHA256(secret, ts \n METHOD \n pathWithQuery \n sha256hex(rawBody)). */
export function signature(secret, ts, method, pathWithQuery, rawBody) {
  const base = `${ts}\n${String(method).toUpperCase()}\n${pathWithQuery}\n${sha256hex(rawBody ?? "")}`;
  return "v1=" + crypto.createHmac("sha256", secret).update(base).digest("hex");
}

/**
 * Checks a request from the platform. rawBody: Buffer (exact bytes). now: unix seconds.
 * -> { ok: true } | { ok: false, reason }
 */
export function verify({ headers, method, path, rawBody, secret, now = Math.floor(Date.now() / 1000) }) {
  if (!secret) return { ok: false, reason: "not_configured" };
  if (headers["x-tretu-app"] !== "platform") return { ok: false, reason: "app" };
  const ts = String(headers["x-tretu-timestamp"] ?? "");
  if (!/^\d{1,12}$/.test(ts) || Math.abs(now - Number(ts)) > MAX_SKEW_SEC) return { ok: false, reason: "timestamp" };
  const got = Buffer.from(String(headers["x-tretu-signature"] ?? ""));
  const want = Buffer.from(signature(secret, ts, method, path, rawBody));
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return { ok: false, reason: "signature" };
  return { ok: true };
}

/** Parsed, validated envelope or null. */
export function parseEnvelope(rawBody) {
  let e;
  try { e = JSON.parse(rawBody.toString("utf8")); } catch { return null; }
  if (!e || typeof e !== "object" || Array.isArray(e)) return null;
  if (typeof e.id !== "string" || e.id.length < 1 || e.id.length > 100) return null;
  if (typeof e.type !== "string" || e.type.length > 64) return null;
  if (e.sub !== null && e.sub !== undefined && (typeof e.sub !== "string" || !SUB.test(e.sub))) return null;
  if (e.data !== undefined && (e.data === null || typeof e.data !== "object" || Array.isArray(e.data))) return null;
  return { id: e.id, type: e.type, app: e.app, sub: e.sub ?? null, data: e.data ?? {} };
}

/**
 * Handles one webhook delivery. rpc(id, body) calls Nakama with the HTTP key.
 * -> { status, body? }  (5xx makes the platform retry; the Nakama RPCs are idempotent)
 */
export async function handleWebhook({ headers, method, path, rawBody, secret, now }, rpc, log = () => {}) {
  if (!secret) return { status: 503, body: { error: "not_configured" } };
  if (rawBody.length > MAX_BODY_BYTES) return { status: 413, body: { error: "too_large" } };
  const v = verify({ headers, method, path, rawBody, secret, now });
  if (!v.ok) {
    log(`tretu webhook rejected (${v.reason})`);
    return { status: 401, body: { error: "unauthorized" } };
  }
  const e = parseEnvelope(rawBody);
  if (!e) return { status: 400, body: { error: "invalid_event" } };
  if (e.type !== "user.deleted" && e.type !== "user.updated") return { status: 204 };
  if (!e.sub) return { status: 400, body: { error: "sub_required" } };
  try {
    if (e.type === "user.deleted") {
      const merged = typeof e.data.mergedInto === "string" && SUB.test(e.data.mergedInto) ? e.data.mergedInto : undefined;
      const out = await rpc("tretu_user_deleted", merged ? { sub: e.sub, mergedInto: merged } : { sub: e.sub });
      log(`tretu webhook ${e.id} user.deleted: ${JSON.stringify(out)}`);
      return { status: 200, body: { ok: true } };
    }
    await rpc("tretu_user_updated", { sub: e.sub, data: e.data });
    return { status: 200, body: { ok: true } };
  } catch (err) {
    log(`tretu webhook ${e.id} ${e.type} failed: ${err?.message || err}`);
    return { status: 503, body: { error: "retry" } };
  }
}
