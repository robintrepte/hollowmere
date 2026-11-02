// Log format of hollowmere-mcp (log.mjs): one JSON object per line with ts, level, msg + context.
//   node --test server/mcp/log.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { makeLogger, cleanContext } from "./log.mjs";

test("one JSON object per line: ts (ISO-8601), level, msg, then context", () => {
  const out = [], err = [];
  const log = makeLogger({ out: (l) => out.push(l), err: (l) => err.push(l), now: () => new Date("2026-11-02T10:00:00.123Z") });
  log.info("hollowmere-mcp started", { port: 8787, webhook: "on" });
  log.warn("tretu webhook rejected", { reason: "bad_signature", remote: "203.0.113.7" });
  log.error("health error", { checks: { db: "error" } });
  assert.equal(out.length, 1); assert.equal(err.length, 2, "warn and error go to stderr");
  for (const line of [...out, ...err]) {
    assert.ok(!line.includes("\n"));
    const o = JSON.parse(line);
    assert.deepEqual(Object.keys(o).slice(0, 3), ["ts", "level", "msg"]);
    assert.match(o.ts, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
  }
  assert.deepEqual(JSON.parse(out[0]), { ts: "2026-11-02T10:00:00.123Z", level: "info", msg: "hollowmere-mcp started", port: 8787, webhook: "on" });
  assert.equal(JSON.parse(err[1]).checks.db, "error");
});

test("context can't overwrite ts/level/msg, secret-looking fields are dropped, long values clipped", () => {
  const c = cleanContext({ ts: "x", level: "x", msg: "x", secret: "s", signature: "v1=…", token: "hm_x", authorization: "Bearer y",
    body: "{}", http_key: "k", nested: { password: "p", ok: 1 }, long: "a".repeat(500), err: new Error("boom"), n: null, skip: undefined });
  assert.deepEqual(Object.keys(c).sort(), ["err", "long", "n", "nested"]);
  assert.deepEqual(c.nested, { ok: 1 });
  assert.equal(c.long.length, 201); assert.equal(c.err, "boom");
});

test("the relay logs its start as JSON", async () => {
  const child = spawn(process.execPath, ["server.mjs"], { cwd: import.meta.dirname,
    env: { ...process.env, MCP_PORT: "0", MCP_HOST: "127.0.0.1", TRETU_APP_SECRET: "start-secret-0123456789abcdef", NAKAMA_HTTP_KEY: "start-http-key-0123" } });
  let text = "";
  child.stdout.on("data", (d) => (text += d));
  const deadline = Date.now() + 20000;
  while (!text.includes("\n") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
  child.kill("SIGTERM");
  const o = JSON.parse(text.split("\n")[0]);
  assert.equal(o.level, "info"); assert.equal(o.msg, "hollowmere-mcp started"); assert.equal(o.webhook, "on");
  assert.ok(!text.includes("start-secret") && !text.includes("start-http-key"));
});
