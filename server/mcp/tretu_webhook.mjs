// Tretu platform webhook for Hollowmere: POST /api/tretu/webhook (contract §3 signature, §4 events).
// Served by the hollowmere-mcp process (PM2), proxied by nginx on hollowmere.tretu.de.
//
// Off unless TRETU_APP_SECRET is set for hollowmere-mcp (server/.env): it must equal the
// hollowmere secret in TRETU_APPS_JSON on tretu.de (and TRETU_APP_SECRET in Nakama's runtime env).
//
//   user.deleted -> Nakama RPC tretu_user_deleted {sub, mergedInto?}   (deletes or merges the farm)
//   user.updated -> Nakama RPC tretu_user_updated {sub, data, occurredAt} (linked ids, username,
//                   account lock: data.locked true disables the "tretu:<sub>" account, false enables it)
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
  // occurredAt orders retries (an older lock never undoes a newer unlock); anything odd is dropped, not fatal.
  const occurredAt = typeof e.occurredAt === "string" && e.occurredAt.length <= 40 && !Number.isNaN(Date.parse(e.occurredAt))
    ? new Date(e.occurredAt).toISOString() : undefined;
  return { id: e.id, type: e.type, app: e.app, sub: e.sub ?? null, occurredAt, data: e.data ?? {} };
}

/** Why a delivery was refused, as logged (verify() reasons -> log reasons). */
export const REJECT_REASONS = { app: "wrong_app", timestamp: "stale_timestamp", signature: "bad_signature" };
const SAFE = (v, max = 100) => (typeof v === "string" && /^[\w.:@-]{1,200}$/.test(v) ? v.slice(0, max) : undefined);

/**
 * What may be logged about a delivery: the app id header, the event id and type if the body parses,
 * the remote address. Never the body, the signature, the secret or any token.
 */
export function deliveryContext(headers, rawBody, remote) {
  let id, type;
  try {
    const e = JSON.parse(rawBody.length <= MAX_BODY_BYTES ? rawBody.toString("utf8") : "null");
    if (e && typeof e === "object") { id = SAFE(e.id); type = SAFE(e.type, 64); }
  } catch { /* not JSON: nothing to add */ }
  return { app: SAFE(String(headers["x-tretu-app"] ?? ""), 64) ?? null, eventId: id, eventType: type, remote: SAFE(remote ?? "", 64) };
}

const noLog = { info() {}, warn() {}, error() {} };

/**
 * Handles one webhook delivery. rpc(id, body) calls Nakama with the HTTP key; log is a structured
 * logger (log.mjs); remote is the client address for the log.
 * -> { status, body? }  (5xx makes the platform retry; the Nakama RPCs are idempotent)
 */
export async function handleWebhook({ headers, method, path, rawBody, secret, now, remote }, rpc, log = noLog) {
  const ctx = () => deliveryContext(headers, rawBody, remote);
  const reject = (status, reason, error) => {
    log.warn("tretu webhook rejected", { reason, status, ...ctx() });
    return { status, body: { error } };
  };
  if (!secret) return reject(503, "not_configured", "not_configured");
  if (rawBody.length > MAX_BODY_BYTES) return reject(413, "body_too_large", "too_large");
  const v = verify({ headers, method, path, rawBody, secret, now });
  if (!v.ok) return reject(401, REJECT_REASONS[v.reason] || v.reason, "unauthorized");
  const e = parseEnvelope(rawBody);
  if (!e) return reject(400, "malformed", "invalid_event");
  if (e.type !== "user.deleted" && e.type !== "user.updated") {
    log.info("tretu webhook ignored", { status: 204, ...ctx() });
    return { status: 204 };
  }
  if (!e.sub) return reject(400, "malformed", "sub_required");
  try {
    if (e.type === "user.deleted") {
      const merged = typeof e.data.mergedInto === "string" && SUB.test(e.data.mergedInto) ? e.data.mergedInto : undefined;
      const out = await rpc("tretu_user_deleted", merged ? { sub: e.sub, mergedInto: merged } : { sub: e.sub });
      log.info("tretu webhook handled", { status: 200, merged: !!merged, result: out, ...ctx() });
      return { status: 200, body: { ok: true } };
    }
    const out = await rpc("tretu_user_updated", e.occurredAt ? { sub: e.sub, data: e.data, occurredAt: e.occurredAt } : { sub: e.sub, data: e.data });
    log.info("tretu webhook handled", { status: 200, lock: typeof e.data.locked === "boolean" ? (out?.lock ?? null) : undefined, ...ctx() });
    return { status: 200, body: { ok: true } };
  } catch (err) {
    log.error("tretu webhook rejected", { reason: "nakama_error", status: 503, error: String(err?.message || err).slice(0, 200), ...ctx() });
    return { status: 503, body: { error: "retry" } };
  }
}
