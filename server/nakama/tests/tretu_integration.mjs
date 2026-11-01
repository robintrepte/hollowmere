#!/usr/bin/env node
// End-to-end test of the Tretu integration on a real Nakama + Postgres, no Docker:
// a fake OIDC issuer and a fake platform (both on 127.0.0.1) check what Nakama does.
//
//   NAKAMA_BIN=/opt/nakama/nakama node server/nakama/tests/tretu_integration.mjs
//
// Env: NAKAMA_BIN (binary), TEST_DB (default postgres@127.0.0.1:5432/nakama_test; the database is
// dropped and recreated, so never point this at real data), PSQL (default psql).
// Ports used: 17350 (API), 17351 (console), 18787 (MCP relay), random for the fakes.
import http from "node:http";
import crypto from "node:crypto";
import { spawn, execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const here = import.meta.dirname;
const repo = path.resolve(here, "../../..");
const TEST_DB = process.env.TEST_DB || "postgres@127.0.0.1:5432/nakama_test";
const PSQL = process.env.PSQL || "psql";
const API = "http://127.0.0.1:17350";
const SERVER_KEY = "hollowmere_dev";
const HTTP_KEY = "integration_http_key";
const SECRET = "integration-secret-0123456789abcdef";
const SUB_ALICE = "7f0c3c2e-8d1b-4f5a-9b6e-2c1d0e9f8a7b";
const SUB_BOB = "1a2b3c4d-0000-4000-8000-00000000b0b0";
const SUB_BOB2 = "1a2b3c4d-0000-4000-8000-00000000b0b2";

let failures = 0;
const check = (name, cond, extra) => {
  if (cond) console.log("ok   " + name);
  else { failures++; console.log("FAIL " + name, extra === undefined ? "" : JSON.stringify(extra)); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- Fake issuer + platform ---------------------------------------------------------------------
const users = {
  "tok-alice": { sub: SUB_ALICE, preferred_username: "alice", discord_id: "123456789012" },
  "tok-bobby1": { sub: SUB_BOB, preferred_username: "bobby" },
  "tok-bobby2": { sub: SUB_BOB2, preferred_username: "bobby" },
};
const received = [];
let platformDown = false;
const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
function verify(req, raw) {
  const ts = req.headers["x-tretu-timestamp"] || "";
  const base = `${ts}\n${req.method}\n${req.url}\n${sha256(raw)}`;
  const want = "v1=" + crypto.createHmac("sha256", SECRET).update(base).digest("hex");
  const got = String(req.headers["x-tretu-signature"] || "");
  const fresh = Math.abs(Date.now() / 1000 - Number(ts)) <= 300;
  return req.headers["x-tretu-app"] === "hollowmere" && fresh && got.length === want.length
    && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(want));
}
const fake = http.createServer((req, res) => {
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    const origin = `http://127.0.0.1:${fake.address().port}`;
    const send = (code, body) => {
      res.writeHead(code, { "Content-Type": "application/json" });
      res.end(body === undefined ? "" : JSON.stringify(body));
    };
    if (req.url === "/.well-known/openid-configuration") {
      return send(200, { issuer: origin, authorization_endpoint: origin + "/authorize", token_endpoint: origin + "/token", userinfo_endpoint: origin + "/userinfo" });
    }
    if (req.url === "/userinfo") {
      const tok = String(req.headers.authorization || "").replace(/^Bearer /, "");
      return users[tok] ? send(200, users[tok]) : send(401, { error: "invalid_token" });
    }
    if (req.url.startsWith("/api/v1/")) {
      const ok = verify(req, raw);
      received.push({ method: req.method, url: req.url, ok, body: raw ? JSON.parse(raw) : null });
      if (!ok) return send(401, { error: "unauthorized" });
      if (platformDown) return send(503, { error: "down" });
      if (req.url === "/api/v1/events") return send(202, { accepted: (JSON.parse(raw).events || [1]).length, duplicates: 0 });
      return send(204);
    }
    send(404, { error: "not found" });
  });
});
await new Promise((r) => fake.listen(0, "127.0.0.1", r));
const FAKE = `http://127.0.0.1:${fake.address().port}`;

// --- Database + Nakama ------------------------------------------------------------------------
const dbName = TEST_DB.split("/").pop();
const dbAdmin = TEST_DB.replace(/\/[^/]+$/, "/postgres");
execFileSync(PSQL, [`postgres://${dbAdmin}`, "-qc", `DROP DATABASE IF EXISTS ${dbName}`], { stdio: "inherit" });
execFileSync(PSQL, [`postgres://${dbAdmin}`, "-qc", `CREATE DATABASE ${dbName}`], { stdio: "inherit" });
const sql = (q) => execFileSync(PSQL, [`postgres://${TEST_DB}`, "-Atqc", q]).toString().trim();

const tmp = mkdtempSync(path.join(tmpdir(), "hm-tretu-"));
const localYml = path.join(tmp, "local.yml");
writeFileSync(localYml, `runtime:
  http_key: "${HTTP_KEY}"
  env:
    - "TRETU_AUTH_ISSUER=${FAKE}"
    - "TRETU_PLATFORM_URL=${FAKE}"
    - "TRETU_APP_ID=hollowmere"
    - "TRETU_APP_SECRET=${SECRET}"
`);
const nakamaLog = [];
const nakama = spawn("bash", [path.join(repo, "server/nakama/nakama.sh"), "start", "--socket.port", "17350", "--console.port", "17351"], {
  env: { ...process.env, NAKAMA_LOCAL_CONFIG: localYml, NAKAMA_DATABASE_ADDRESS: TEST_DB, NAKAMA_DATA_DIR: path.join(tmp, "data") },
  stdio: ["ignore", "pipe", "pipe"],
});
nakama.stdout.on("data", (d) => nakamaLog.push(d.toString()));
nakama.stderr.on("data", (d) => nakamaLog.push(d.toString()));
let mcp = null;
const cleanup = () => {
  nakama.kill("SIGINT");
  if (mcp) mcp.kill();
  fake.close();
  rmSync(tmp, { recursive: true, force: true });
};

async function api(method, url, { body, session, basic } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (session) headers.Authorization = "Bearer " + session;
  if (basic) headers.Authorization = "Basic " + Buffer.from(SERVER_KEY + ":").toString("base64");
  const res = await fetch(API + url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let json = {};
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  return { status: res.status, json };
}
const rpc = async (session, id, payload = {}) => {
  const r = await api("POST", `/v2/rpc/${id}`, { session, body: JSON.stringify(payload) });
  return { status: r.status, json: r.json.payload ? JSON.parse(r.json.payload) : r.json };
};
const tretuLogin = (token, create = true) =>
  api("POST", `/v2/account/authenticate/custom?create=${create}`, { basic: true, body: { id: "tretu-login", vars: { tretu_token: token } } });
const claims = (jwt) => JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString());
const save = (session, slot, meta) => api("PUT", "/v2/storage", {
  session, body: { objects: [{ collection: "saves", key: slot, value: JSON.stringify({ version: 3, meta }), permission_read: 1, permission_write: 1 }] },
});

try {
  let up = false;
  for (let i = 0; i < 60 && !up; i++) {
    await sleep(500);
    up = await fetch(API + "/healthcheck").then((r) => r.ok, () => false);
  }
  check("nakama is up", up, nakamaLog.join("").slice(-2000));
  if (!up) throw new Error("nakama did not start");
  check("signing self-test logged ok", nakamaLog.join("").includes("Tretu signing self-test ok"));

  // An existing Discord player with a cloud save.
  const dev = await api("POST", "/v2/account/authenticate/device?create=true", { basic: true, body: { id: "integration-device-0001" } });
  const discordUser = claims(dev.json.token).uid;
  sql(`UPDATE users SET custom_id = 'discord:123456789012' WHERE id = '${discordUser}'`);
  const before = await save(dev.json.token, "slot_0", { farm: "Moss", day: 5, befriended: 2 });
  check("discord player saved a farm", before.status === 200, before.json);

  // Tretu login with the same Discord id carries the account over.
  const a1 = await tretuLogin("tok-alice");
  check("tretu login ok", a1.status === 200, a1.json);
  const c1 = claims(a1.json.token);
  check("same Nakama user as the Discord account", c1.uid === discordUser, { uid: c1.uid, discordUser });
  check("custom id re-keyed", sql(`SELECT custom_id FROM users WHERE id = '${discordUser}'`) === `tretu:${SUB_ALICE}`);
  check("session carries tretu_sub, not the token", c1.vrs?.tretu_sub === SUB_ALICE && !JSON.stringify(c1).includes("tok-alice"), c1.vrs);
  check("discord marker stored", sql("SELECT value->>'custom_id' FROM storage WHERE collection = 'tretu_links' AND key = 'discord:123456789012'") === `tretu:${SUB_ALICE}`);
  const list = await api("GET", `/v2/storage/saves/${discordUser}?limit=10`, { session: a1.json.token });
  check("cloud save still there", (list.json.objects || []).some((o) => o.key === "slot_0"), list.json);
  const a2 = await tretuLogin("tok-alice");
  check("second login is idempotent", a2.status === 200 && claims(a2.json.token).uid === discordUser);
  check("no extra account created", sql(`SELECT count(*) FROM users WHERE custom_id LIKE 'tretu:%'`) === "1");

  // New Tretu players get their preferred name, unique.
  const b1 = await tretuLogin("tok-bobby1");
  const b2 = await tretuLogin("tok-bobby2");
  check("new tretu account created", b1.status === 200 && b2.status === 200, [b1.json, b2.json]);
  const n1 = claims(b1.json.token).usn, n2 = claims(b2.json.token).usn;
  check("username from preferred_username", n1 === "bobby", n1);
  check("username collision gets a suffix", /^bobby_\d{4}$/.test(n2), n2);
  const bad = await tretuLogin("tok-nobody");
  check("unknown token is rejected", bad.status === 401, bad);
  const raw = await api("POST", "/v2/account/authenticate/custom?create=true", { basic: true, body: { id: `tretu:${SUB_ALICE}` } });
  check("custom id without a token is refused", raw.status >= 400 && raw.status < 500, raw);

  // Progress from cloud saves -> queued stat events -> heartbeat delivers them (signed).
  const s1 = a1.json.token;
  await save(s1, "slot_0", { farm: "Moss", day: 5, befriended: 2 }); // baseline
  await save(s1, "slot_0", { farm: "Moss", day: 8, befriended: 4 });
  check("save hook sent nothing yet", received.filter((r) => r.url === "/api/v1/events").length === 0);
  const hb = await rpc(s1, "tretu_heartbeat", {});
  check("heartbeat enabled", hb.status === 200 && hb.json.enabled === true, hb);
  const pres = received.find((r) => r.method === "PUT" && r.url === `/api/v1/presence/${SUB_ALICE}`);
  check("presence sent and signed", pres?.ok && pres.body.status === "playing" && pres.body.activity === "Hollowmere", pres);
  const ev = received.find((r) => r.url === "/api/v1/events");
  check("events signed", ev?.ok === true, ev);
  const evs = ev?.body?.events || [];
  const byKey = Object.fromEntries(evs.map((e) => [e.data.key, e]));
  check("days.played +3", byKey["hollowmere.days.played"]?.data.by === 3, evs);
  check("creatures.befriended +2", byKey["hollowmere.creatures.befriended"]?.data.by === 2, evs);
  check("envelope fields", evs.every((e) => e.app === "hollowmere" && e.sub === SUB_ALICE && e.type === "stat.increment"
    && /^[0-9a-f-]{36}$/.test(e.id) && !Number.isNaN(Date.parse(e.occurredAt))), evs);
  check("outbox emptied", sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_outbox' AND user_id = '${discordUser}'`) === "0");
  const hb2 = await rpc(s1, "tretu_heartbeat", {});
  check("heartbeat is throttled", hb2.json.throttled === true, hb2);

  // Battles: game.finished, retried when the platform is down.
  const sb = b1.json.token;
  platformDown = true;
  const bt = await rpc(sb, "tretu_report_battle", { result: "win", kind: "wild" });
  check("battle report accepted", bt.status === 200 && bt.json.enabled === true, bt);
  check("battle kept in the outbox while the platform is down",
    sql(`SELECT jsonb_array_length(value->'events') FROM storage WHERE collection = 'tretu_outbox' AND user_id = '${claims(sb).uid}'`) === "1");
  platformDown = false;
  const code = await rpc(sb, "create_coop_code", { match_id: "integration-match-0001" });
  check("co-op code", typeof code.json.code === "string", code);
  await rpc(sb, "tretu_heartbeat", { code: code.json.code });
  const bobPres = received.filter((r) => r.url === `/api/v1/presence/${SUB_BOB}` && r.method === "PUT").pop();
  check("presence joinUrl while hosting", bobPres?.body?.joinUrl === `https://hollowmere.tretu.de/?join=${code.json.code}`, bobPres);
  const battle = received.filter((r) => r.url === "/api/v1/events" && r.ok).flatMap((r) => r.body.events).find((e) => e.type === "game.finished");
  check("game.finished delivered after retry", battle?.data?.game === "battle" && battle.data.result === "win" && battle.data.mode === "bot" && battle.sub === SUB_BOB, battle);
  const badResult = await rpc(sb, "tretu_report_battle", { result: "flawless" });
  check("bad battle result rejected", badResult.status === 400, badResult);
  await rpc(sb, "tretu_offline", {});
  check("offline clears presence", received.some((r) => r.method === "DELETE" && r.url === `/api/v1/presence/${SUB_BOB}` && r.ok));

  // A non-Tretu player: nothing goes to the platform.
  const before2 = received.length;
  const guest = await api("POST", "/v2/account/authenticate/device?create=true", { basic: true, body: { id: "integration-device-0002" } });
  const g = await rpc(guest.json.token, "tretu_heartbeat", {});
  check("guest heartbeat is a no-op", g.json.enabled === false && received.length === before2, g);
  check("every platform request was correctly signed", received.every((r) => r.ok), received.filter((r) => !r.ok));

  // /api/health through the MCP relay.
  mcp = spawn(process.execPath, [path.join(repo, "server/mcp/server.mjs")], {
    env: { ...process.env, MCP_PORT: "18787", NAKAMA_URL: API, NAKAMA_HTTP_KEY: HTTP_KEY }, stdio: "ignore",
  });
  let health = null;
  for (let i = 0; i < 40 && !health; i++) {
    await sleep(250);
    health = await fetch("http://127.0.0.1:18787/api/health").then(async (r) => ({ status: r.status, body: await r.json() }), () => null);
  }
  check("/api/health ok", health?.status === 200 && health.body.status === "ok" && health.body.app === "hollowmere" && health.body.checks.db === "ok", health);
} catch (e) {
  failures++;
  console.log("FAIL exception", e?.stack || e);
} finally {
  cleanup();
}
console.log(`TRETU INTEGRATION DONE, ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
