// Unit tests for the Tretu webhook (contract §3 signature incl. the test vectors, §4 events).
//   node server/mcp/tretu_webhook.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { signature, verify, parseEnvelope, handleWebhook, MAX_BODY_BYTES } from "./tretu_webhook.mjs";
import { makeLogger } from "./log.mjs";

/** A real logger (log.mjs) writing into an array: [{ts, level, msg, ...}] plus the raw lines. */
function capture() {
  const lines = [];
  const logger = makeLogger({ out: (l) => lines.push(l), err: (l) => lines.push(l) });
  return { logger, lines, entries: () => lines.map((l) => JSON.parse(l)) };
}

const VECTOR_BODY = '{"id":"0b9f1c2e-1111-4a5b-8c9d-123456789abc","type":"stat.increment","app":"saga","sub":"user-sub-1","occurredAt":"2026-01-01T00:00:00.000Z","data":{"key":"saga.turns","by":1}}';
const SECRET = "hook-secret-0123456789abcdef0123";
const PATH = "/api/tretu/webhook";
const NOW = 1767225600;

test("contract §3 test vectors", () => {
  assert.equal(signature("test-secret-123", "1767225600", "POST", "/api/v1/events", Buffer.from(VECTOR_BODY)),
    "v1=f1a93767113e533347f3fc19e2ea26de609e2848ca366017516d7752c230243d");
  assert.equal(signature("test-secret-123", "1767225600", "GET", "/api/v1/wallet/user-sub-1", Buffer.alloc(0)),
    "v1=2b0726b5f46af3137ecc0e51e27183533e357d620e2ab128fd7165610bc9ca6f");
});

function signed(body, { ts = NOW, app = "platform", secret = SECRET, path = PATH } = {}) {
  const rawBody = Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
  return {
    headers: { "x-tretu-app": app, "x-tretu-timestamp": String(ts), "x-tretu-signature": signature(secret, String(ts), "POST", path, rawBody) },
    method: "POST", path: PATH, rawBody, secret: SECRET, now: NOW,
  };
}
const envelope = (type, sub, data = {}) => ({ id: "11111111-2222-4333-8444-555555555555", type, app: "platform", sub, occurredAt: "2026-01-01T00:00:00.000Z", data });

test("verify accepts a correct platform signature", () => {
  assert.deepEqual(verify(signed(envelope("user.deleted", "s1"))), { ok: true });
});

test("verify rejects forged, stale, foreign and unconfigured requests", () => {
  const r = signed(envelope("user.deleted", "s1"));
  assert.equal(verify({ ...r, headers: { ...r.headers, "x-tretu-signature": "v1=" + "0".repeat(64) } }).reason, "signature");
  assert.equal(verify({ ...r, rawBody: Buffer.from(r.rawBody.toString().replace("s1", "s2")) }).reason, "signature", "body is covered");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { secret: "other-secret" })).reason, "signature");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { path: "/other" })).reason, "signature", "path is covered");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { ts: NOW - 301 })).reason, "timestamp", "replay after 5 min");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { ts: NOW + 301 })).reason, "timestamp");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { ts: NOW - 300 })).ok, true, "±300 s inclusive");
  assert.equal(verify(signed(envelope("user.deleted", "s1"), { app: "saga" })).reason, "app");
  assert.equal(verify({ ...r, headers: { ...r.headers, "x-tretu-signature": "short" } }).reason, "signature");
  assert.equal(verify({ ...r, secret: "" }).reason, "not_configured");
});

test("envelope validation", () => {
  assert.equal(parseEnvelope(Buffer.from("nope")), null);
  assert.equal(parseEnvelope(Buffer.from("[]")), null);
  assert.equal(parseEnvelope(Buffer.from(JSON.stringify({ ...envelope("user.deleted", "a/b") }))), null);
  assert.equal(parseEnvelope(Buffer.from(JSON.stringify({ ...envelope("user.deleted", "a"), data: [] }))), null);
  assert.deepEqual(parseEnvelope(Buffer.from(JSON.stringify(envelope("x", null)))).sub, null);
});

function fakeRpc(fail = false) {
  const calls = [];
  const rpc = async (id, body) => {
    calls.push({ id, body });
    if (fail) throw new Error("nakama down");
    return { ok: true };
  };
  return { calls, rpc };
}

test("user.deleted calls Nakama with the sub", async () => {
  const { calls, rpc } = fakeRpc();
  const out = await handleWebhook(signed(envelope("user.deleted", "sub-1")), rpc);
  assert.equal(out.status, 200);
  assert.deepEqual(calls, [{ id: "tretu_user_deleted", body: { sub: "sub-1" } }]);
});

test("user.deleted with mergedInto passes it on", async () => {
  const { calls, rpc } = fakeRpc();
  await handleWebhook(signed(envelope("user.deleted", "old", { mergedInto: "new" })), rpc);
  assert.deepEqual(calls[0].body, { sub: "old", mergedInto: "new" });
  await handleWebhook(signed(envelope("user.deleted", "old", { mergedInto: "x/../y" })), rpc);
  assert.deepEqual(calls[1].body, { sub: "old" }, "a malformed mergedInto is not forwarded");
});

test("user.updated refreshes, unknown types are 204, nothing reaches Nakama unsigned", async () => {
  const { calls, rpc } = fakeRpc();
  const data = { sub: "s", username: "mia", links: { steam: "76561198000000001" } };
  assert.equal((await handleWebhook(signed(envelope("user.updated", "s", data)), rpc)).status, 200);
  assert.deepEqual(calls[0], { id: "tretu_user_updated", body: { sub: "s", data, occurredAt: "2026-01-01T00:00:00.000Z" } });
  assert.equal((await handleWebhook(signed(envelope("badge.earned", "s", { badge: "x" })), rpc)).status, 204);
  assert.equal((await handleWebhook(signed(envelope("wallet.changed", "s")), rpc)).status, 204);
  const forged = signed(envelope("user.deleted", "s"), { secret: "attacker" });
  assert.equal((await handleWebhook(forged, rpc)).status, 401);
  assert.equal(calls.length, 1);
});

test("user.updated with locked reaches Nakama with the event time (orders retries); odd times are dropped", async () => {
  const { calls, rpc } = fakeRpc();
  const cap = capture();
  const lock = { ...envelope("user.updated", "s", { sub: "s", locked: true }), occurredAt: "2026-03-04T05:06:07.890+01:00" };
  assert.equal((await handleWebhook(signed(lock), rpc, cap.logger)).status, 200);
  assert.deepEqual(calls[0], { id: "tretu_user_updated", body: { sub: "s", data: { sub: "s", locked: true }, occurredAt: "2026-03-04T04:06:07.890Z" } });
  const handled = cap.entries().find((e) => e.msg === "tretu webhook handled");
  assert.ok(handled && "lock" in handled && handled.eventType === "user.updated", "a lock is logged (without secrets)");
  const odd = { ...envelope("user.updated", "s", { sub: "s", locked: false }), occurredAt: "yesterday" };
  await handleWebhook(signed(odd), rpc);
  assert.deepEqual(calls[1], { id: "tretu_user_updated", body: { sub: "s", data: { sub: "s", locked: false } } });
  const down = fakeRpc(true);
  assert.equal((await handleWebhook(signed(lock), down.rpc)).status, 503, "the platform retries a lock Nakama could not apply");
});

test("bad input and Nakama trouble", async () => {
  const { rpc } = fakeRpc();
  assert.equal((await handleWebhook(signed("{not json"), rpc)).status, 400);
  assert.equal((await handleWebhook(signed(envelope("user.deleted", null)), rpc)).status, 400);
  const big = signed(envelope("user.updated", "s", { pad: "x".repeat(MAX_BODY_BYTES) }));
  assert.equal((await handleWebhook(big, rpc)).status, 413);
  const down = fakeRpc(true);
  assert.equal((await handleWebhook(signed(envelope("user.deleted", "s")), down.rpc)).status, 503, "platform retries");
  const r = signed(envelope("user.deleted", "s"));
  assert.equal((await handleWebhook({ ...r, secret: "" }, rpc)).status, 503, "off until configured");
});

test("rejected deliveries are logged with the reason, app, event and address, never secret material", async () => {
  const { rpc } = fakeRpc();
  const cap = capture();
  const remote = "203.0.113.7";
  const run = (req) => handleWebhook({ ...req, remote }, rpc, cap.logger);
  const ev = envelope("user.deleted", "sub-9");
  const forged = signed(ev, { secret: "attacker-secret-0123456789" });
  await run(forged);
  await run(signed(ev, { ts: NOW - 999 }));
  await run(signed(ev, { app: "saga" }));
  await run(signed(envelope("user.updated", "s", { pad: "x".repeat(MAX_BODY_BYTES) })));
  await run(signed("{not json"));
  await run(signed(envelope("user.deleted", null)));
  await run({ ...signed(ev), secret: "" });
  await handleWebhook({ ...signed(ev), remote }, fakeRpc(true).rpc, cap.logger);
  const rejected = cap.entries().filter((e) => e.msg === "tretu webhook rejected");
  assert.deepEqual(rejected.map((e) => e.reason),
    ["bad_signature", "stale_timestamp", "wrong_app", "body_too_large", "malformed", "malformed", "not_configured", "nakama_error"]);
  assert.deepEqual(rejected.map((e) => e.level), ["warn", "warn", "warn", "warn", "warn", "warn", "warn", "error"]);
  for (const e of rejected) assert.equal(e.remote, remote);
  const sig = rejected[0];
  assert.equal(sig.app, "platform"); assert.equal(sig.eventId, ev.id); assert.equal(sig.eventType, "user.deleted"); assert.equal(sig.status, 401);
  assert.equal(rejected[2].app, "saga");
  assert.equal(rejected[4].eventId, undefined, "unparseable body: no event fields");
  assert.equal(rejected[3].eventId, undefined, "an oversized body is not parsed");
  const all = cap.lines.join("\n");
  for (const secret of [SECRET, "attacker-secret-0123456789", forged.headers["x-tretu-signature"], forged.headers["x-tretu-signature"].slice(3), "sub-9", '"pad"', "xxxxxxxxxx"]) {
    assert.ok(!all.includes(secret), "leaked: " + secret.slice(0, 20));
  }
});
