#!/usr/bin/env node
// End-to-end test of the Tretu integration on a real Nakama + Postgres, no Docker:
// a fake OIDC issuer and a fake platform (both on 127.0.0.1) check what Nakama does:
// sign-in + Discord/Steam carry-over, platform events, the in-game wallet/notification summary,
// choosing a farm when two accounts exist (archive, restore, atomicity, idempotency), purge.
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
const SUB_CAROL = "c0c0c0c0-0000-4000-8000-00000000ca01";
const SUB_DAVE = "d0d0d0d0-0000-4000-8000-00000000da01";
const SUB_ERIN = "e0e0e0e0-0000-4000-8000-00000000e401";
const SUB_GHOST = "90909090-0000-4000-8000-000000000404";
const STEAM_DAVE = "76561198000000001";
const STEAM_ERIN = "76561198000000002";
const BACKOFF_SEC = 2;

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
  "tok-carol": { sub: SUB_CAROL, preferred_username: "carol" },
  "tok-dave": { sub: SUB_DAVE, preferred_username: "dave", steam_id: STEAM_DAVE },
  "tok-erin": { sub: SUB_ERIN, preferred_username: "erin" },
  "tok-ghost": { sub: SUB_GHOST, preferred_username: "ghost" },
};
const received = [];
let platformDown = false;
let platformHang = false;
const wallets = { [SUB_ALICE]: 120, [SUB_BOB]: 7 };
const unread = { [SUB_ALICE]: 3 };
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
      if (platformHang) return; // never answers: Nakama's timeout must end the wait
      if (platformDown) return send(503, { error: "down" });
      if (req.url === "/api/v1/events") return send(202, { accepted: (JSON.parse(raw).events || [1]).length, duplicates: 0 });
      let m = req.url.match(/^\/api\/v1\/wallet\/([\w-]+)$/);
      if (m && req.method === "GET") {
        if (m[1] === SUB_GHOST) return send(404, { error: "user_not_found" });
        return send(200, { sub: m[1], balance: wallets[m[1]] ?? 50, currency: "TC" });
      }
      m = req.url.match(/^\/api\/v1\/users\/([\w-]+)\/notifications\/count$/);
      if (m && req.method === "GET") return send(200, { unreadCount: unread[m[1]] ?? 0 });
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
    - "TRETU_PLATFORM_BACKOFF_SEC=${BACKOFF_SEC}"
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
// Server-to-server RPC with the runtime HTTP key (what the MCP relay and cron jobs use).
const serverRpc = async (id, payload = {}) => {
  const r = await api("POST", `/v2/rpc/${id}?http_key=${HTTP_KEY}`, { body: JSON.stringify(payload) });
  return { status: r.status, json: r.json.payload ? JSON.parse(r.json.payload) : r.json };
};
// The platform remembers an outage for BACKOFF_SEC; wait it out (a timer, not a race with work).
const waitBackoff = () => sleep(BACKOFF_SEC * 1000 + 400);
const deviceUser = async (id) => {
  const r = await api("POST", "/v2/account/authenticate/device?create=true", { basic: true, body: { id } });
  return { token: r.json.token, uid: claims(r.json.token).uid };
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
  const skipped = received.length;
  const hbB2 = await rpc(b2.json.token, "tretu_heartbeat", {});
  check("platform is skipped while backing off after an outage", hbB2.status === 200 && received.length === skipped, received.slice(skipped));
  await waitBackoff();
  const code = await rpc(sb, "create_coop_code", { match_id: "integration-match-0001" });
  check("co-op code", typeof code.json.code === "string", code);
  await rpc(sb, "tretu_heartbeat", { code: code.json.code });
  const bobPres = received.filter((r) => r.url === `/api/v1/presence/${SUB_BOB}` && r.method === "PUT").pop();
  check("presence joinUrl while hosting", bobPres?.body?.joinUrl === `https://hollowmere.tretu.de/?join=${code.json.code}`, bobPres);
  const battle = received.filter((r) => r.url === "/api/v1/events" && r.ok).flatMap((r) => r.body.events).find((e) => e.type === "game.finished");
  check("game.finished delivered after the outage", battle?.data?.game === "battle" && battle.data.result === "win" && battle.data.mode === "bot" && battle.sub === SUB_BOB, battle);
  const badResult = await rpc(sb, "tretu_report_battle", { result: "flawless" });
  check("bad battle result rejected", badResult.status === 400, badResult);
  await rpc(sb, "tretu_offline", {});
  check("offline clears presence", received.some((r) => r.method === "DELETE" && r.url === `/api/v1/presence/${SUB_BOB}` && r.ok));

  // A non-Tretu player: nothing goes to the platform.
  const before2 = received.length;
  const guest = await api("POST", "/v2/account/authenticate/device?create=true", { basic: true, body: { id: "integration-device-0002" } });
  const g = await rpc(guest.json.token, "tretu_heartbeat", {});
  check("guest heartbeat is a no-op", g.json.enabled === false && received.length === before2, g);

  // --- In-game Tretu menu: wallet balance + unread notifications (tretu_account) -----------------
  const acc = await rpc(s1, "tretu_account", {});
  check("account summary ok", acc.status === 200 && acc.json.enabled === true && acc.json.state === "ok"
    && acc.json.balance === 120 && acc.json.currency === "TC" && acc.json.unread === 3, acc);
  const walletReq = received.filter((r) => r.url === `/api/v1/wallet/${SUB_ALICE}`);
  const countReq = received.filter((r) => r.url === `/api/v1/users/${SUB_ALICE}/notifications/count`);
  check("summary read from the platform, signed", walletReq.length === 1 && countReq.length === 1
    && walletReq[0].ok && countReq[0].ok && walletReq[0].method === "GET", { walletReq, countReq });
  check("summary never carries the app secret", !JSON.stringify(acc.json).includes(SECRET));
  wallets[SUB_ALICE] = 999;
  const acc2 = await rpc(s1, "tretu_account", { refresh: true });
  check("summary is cached (and a forced refresh right away is not a new platform call)",
    acc2.json.balance === 120 && received.filter((r) => r.url === `/api/v1/wallet/${SUB_ALICE}`).length === 1, acc2);
  const gAcc = await rpc(guest.json.token, "tretu_account", {});
  check("summary is off for players without a Tretu-Konto", gAcc.status === 200 && gAcc.json.enabled === false, gAcc);
  const ghost = await tretuLogin("tok-ghost");
  const gh = await rpc(ghost.json.token, "tretu_account", {});
  check("platform does not know the sub -> unavailable, no outage", gh.json.state === "unavailable" && gh.json.balance === undefined, gh);
  platformDown = true;
  const down = await rpc(sb, "tretu_account", {});
  check("platform down -> friendly 'unavailable', no error", down.status === 200 && down.json.state === "unavailable" && down.json.balance === undefined, down);
  platformDown = false;
  const n0 = received.length;
  const during = await rpc(sb, "tretu_account", {});
  check("no platform call while backing off", during.json.state === "unavailable" && received.length === n0, during);
  await waitBackoff();
  const recovered = await rpc(sb, "tretu_account", {});
  check("summary recovers after the outage", recovered.json.state === "ok" && recovered.json.balance === 7 && recovered.json.unread === 0, recovered);
  platformHang = true;
  const t0 = Date.now();
  const hang = await rpc(b2.json.token, "tretu_account", {});
  const waited = Date.now() - t0;
  platformHang = false;
  check("a hanging platform is cut off by the timeout", hang.status === 200 && hang.json.state === "unavailable" && waited < 15000, { hang, waited });
  await waitBackoff();

  // --- Choose a farm: Tretu account and an old Discord account both exist -----------------------
  const cr1 = await tretuLogin("tok-carol");                       // Tretu account first (no Discord claim yet)
  const carolT = claims(cr1.json.token).uid;
  await save(cr1.json.token, "slot_0", { farm: "Tretu Acres", player: "Carol", day: 3, money: 100, saved_at: 1000 });
  const cd = await deviceUser("integration-device-carol");        // her old Discord account, with a bigger farm
  sql(`UPDATE users SET custom_id = 'discord:555000555' WHERE id = '${cd.uid}'`);
  await save(cd.token, "slot_0", { farm: "Old Willow", player: "Carol", day: 80, money: 9000, befriended: 12, saved_at: 2000 });
  await save(cd.token, "slot_2", { farm: "Second Field", player: "Carol", day: 2, money: 10, saved_at: 1500 });
  users["tok-carol"].discord_id = "555000555";
  const cr2 = await tretuLogin("tok-carol");
  check("both accounts: Tretu login stays on the Tretu account, nothing merged",
    claims(cr2.json.token).uid === carolT && sql(`SELECT custom_id FROM users WHERE id = '${cd.uid}'`) === "discord:555000555");
  let st = cr2.json.token;
  const ch = await rpc(st, "tretu_farm_choice", {});
  const optT = (ch.json.options || []).find((o) => o.id === carolT);
  const optD = (ch.json.options || []).find((o) => o.id === cd.uid);
  check("farm choice pending with both save summaries", ch.status === 200 && ch.json.pending === true && ch.json.keepDays === 90
    && optT?.kind === "tretu" && optT.current === true && optT.saves?.[0]?.farm === "Tretu Acres"
    && optD?.kind === "discord" && optD.current === false && optD.saves?.length === 2
    && optD.saves[0].farm === "Old Willow" && optD.saves[0].day === 80 && optD.saves[0].money === 9000 && optD.saves[0].befriended === 12, ch);
  const badKeep = await rpc(st, "tretu_farm_choose", { keep: "00000000-0000-4000-8000-000000000000" });
  check("choosing a farm that isn't yours is refused", badKeep.status === 404, badKeep);
  const notUuid = await rpc(st, "tretu_farm_choose", { keep: "x'; DROP TABLE users; --" });
  check("a malformed choice is rejected before any SQL", notUuid.status === 400 && sql("SELECT count(*) FROM users") !== "0", notUuid);

  // Atomicity: make the second half of the switch fail -> nothing at all may change.
  sql(`CREATE OR REPLACE FUNCTION hm_test_block() RETURNS trigger AS $$ BEGIN
         IF NEW.id = '${cd.uid}' AND NEW.custom_id LIKE 'tretu:%' THEN RAISE EXCEPTION 'injected failure'; END IF;
         RETURN NEW; END $$ LANGUAGE plpgsql`);
  sql(`CREATE TRIGGER hm_test_block BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION hm_test_block()`);
  const broken = await rpc(st, "tretu_farm_choose", { keep: cd.uid });
  sql("DROP TRIGGER hm_test_block ON users");
  check("failed switch reports a friendly error", broken.status === 500 && /Nothing was changed/.test(JSON.stringify(broken.json)), broken);
  check("failed switch is rolled back completely",
    sql(`SELECT custom_id || '|' || (disable_time > 'epoch') FROM users WHERE id = '${carolT}'`) === `tretu:${SUB_CAROL}|false`
    && sql(`SELECT custom_id FROM users WHERE id = '${cd.uid}'`) === "discord:555000555"
    && sql("SELECT count(*) FROM storage WHERE collection = 'tretu_archive'") === "0");
  const stillOk = await rpc(st, "tretu_farm_choice", {});
  check("session still works after the rollback", stillOk.status === 200 && stillOk.json.pending === true, stillOk);

  // Keep the old Discord farm: the Tretu account is archived, the Discord account becomes tretu:<sub>.
  const kept = await rpc(st, "tretu_farm_choose", { keep: cd.uid });
  check("keep the Discord farm", kept.status === 200 && kept.json.changed === true && kept.json.kept === cd.uid
    && kept.json.archived === 1 && typeof kept.json.token === "string", kept);
  check("Discord account now signs in as the Tretu-Konto", sql(`SELECT custom_id FROM users WHERE id = '${cd.uid}'`) === `tretu:${SUB_CAROL}`);
  check("old Tretu account archived and disabled, not deleted",
    sql(`SELECT custom_id || '|' || (disable_time > 'epoch') FROM users WHERE id = '${carolT}'`) === `archived:${carolT}|true`
    && sql(`SELECT count(*) FROM storage WHERE collection = 'saves' AND user_id = '${carolT}'`) === "1");
  check("archive record kept (sub, old custom id, time)",
    sql(`SELECT value->>'sub' || '|' || (value->>'custom_id') || '|' || (value->>'kind') FROM storage WHERE collection = 'tretu_archive' AND key = '${carolT}'`)
      === `${SUB_CAROL}|tretu:${SUB_CAROL}|tretu`);
  check("archive record is not readable by players", sql(`SELECT read FROM storage WHERE collection = 'tretu_archive' AND key = '${carolT}'`) === "0");
  check("Discord button follows the Tretu-Konto", sql("SELECT value->>'custom_id' FROM storage WHERE collection = 'tretu_links' AND key = 'discord:555000555'") === `tretu:${SUB_CAROL}`);
  const oldSession = await rpc(st, "tretu_farm_choice", {});
  check("session of the archived account ends", oldSession.status === 401, oldSession);
  st = kept.json.token;
  check("new session is for the kept farm, carries only the sub", claims(st).uid === cd.uid && claims(st).vrs?.tretu_sub === SUB_CAROL);
  const after = await rpc(st, "tretu_farm_choice", {});
  const arch = (after.json.options || []).find((o) => o.id === carolT);
  const nowSec = Date.now() / 1000;
  check("nothing pending; archived farm listed as restorable for 90 days", after.json.pending === false
    && after.json.options?.[0]?.id === cd.uid && after.json.options[0].current === true
    && arch?.kind === "archived" && arch.was === "tretu" && arch.saves?.[0]?.farm === "Tretu Acres"
    && Math.abs(arch.restoreUntil - (nowSec + 90 * 86400)) < 120, after);
  const again = await rpc(st, "tretu_farm_choose", { keep: cd.uid });
  check("choosing the same farm again is a no-op", again.status === 200 && again.json.changed === false && !again.json.token, again);
  const cr3 = await tretuLogin("tok-carol");
  check("next Tretu login lands on the kept farm", claims(cr3.json.token).uid === cd.uid);
  const cloud = await api("GET", `/v2/storage/saves/${cd.uid}?limit=10`, { session: cr3.json.token });
  check("kept farm's cloud saves are there", (cloud.json.objects || []).length === 2, cloud.json);
  const archLogin = await api("POST", "/v2/account/authenticate/device?create=false", { basic: true, body: { id: "integration-device-carol" } });
  check("other sign-ins of the kept account still work", archLogin.status === 200);

  // Restore within 90 days: swap back.
  st = cr3.json.token;
  const restored = await rpc(st, "tretu_farm_choose", { keep: carolT });
  check("restore the archived farm", restored.status === 200 && restored.json.changed === true && typeof restored.json.token === "string", restored);
  check("restored account is tretu:<sub> again and enabled",
    sql(`SELECT custom_id || '|' || (disable_time > 'epoch') FROM users WHERE id = '${carolT}'`) === `tretu:${SUB_CAROL}|false`
    && sql(`SELECT custom_id FROM users WHERE id = '${cd.uid}'`) === `archived:${cd.uid}`
    && sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_archive' AND key = '${carolT}'`) === "0");
  const cr4 = await tretuLogin("tok-carol");
  check("Tretu login follows the restore", cr4.status === 200 && claims(cr4.json.token).uid === carolT, cr4);
  const banned = await api("POST", "/v2/account/authenticate/device?create=false", { basic: true, body: { id: "integration-device-carol" } });
  check("archived account cannot be signed into another way", banned.status === 403, banned);

  // Two choices at once (double click, two devices): one wins, state stays consistent.
  const e1 = await tretuLogin("tok-erin");
  const erinT = claims(e1.json.token).uid;
  const es = await deviceUser("integration-device-erin");
  sql(`UPDATE users SET custom_id = 'steam:${STEAM_ERIN}' WHERE id = '${es.uid}'`);
  await save(es.token, "slot_0", { farm: "Steam Hollow", player: "Erin", day: 9, money: 50, saved_at: 3000 });
  users["tok-erin"].steam_id = STEAM_ERIN;
  const e2 = await tretuLogin("tok-erin");
  check("Steam: Tretu login with a steam_id claim records it on the metadata",
    sql(`SELECT metadata->>'steam_id' FROM users WHERE id = '${erinT}'`) === STEAM_ERIN);
  const ech = await rpc(e2.json.token, "tretu_farm_choice", {});
  check("Steam: old steam:<id> account offered as a farm choice", ech.json.pending === true
    && (ech.json.options || []).some((o) => o.id === es.uid && o.kind === "steam" && o.saves?.[0]?.farm === "Steam Hollow"), ech);
  const [r1, r2] = await Promise.all([
    rpc(e2.json.token, "tretu_farm_choose", { keep: erinT }),
    rpc(e2.json.token, "tretu_farm_choose", { keep: erinT }),
  ]);
  const statuses = [r1.status, r2.status];
  check("concurrent identical choices: one applies, the other is a no-op or asks to look again",
    statuses.every((x) => x === 200 || x === 409) && [r1, r2].filter((r) => r.json.changed === true).length === 1, [r1, r2]);
  check("Steam: old Steam account archived, Steam id moved to the kept farm",
    sql(`SELECT custom_id FROM users WHERE id = '${es.uid}'`) === `archived:${es.uid}`
    && sql(`SELECT steam_id FROM users WHERE id = '${erinT}'`) === STEAM_ERIN
    && sql(`SELECT count(*) FROM users WHERE custom_id = 'tretu:${SUB_ERIN}'`) === "1");
  let limited = null;
  for (let i = 0; i < 6 && !limited; i++) {
    const r = await rpc(e2.json.token, "tretu_farm_choose", { keep: erinT });
    if (r.status === 429) limited = r;
  }
  check("farm choice is rate limited", limited !== null, limited);
  delete users["tok-erin"].steam_id;
  await tretuLogin("tok-erin");
  check("Steam: unlinking Steam removes it from the metadata", sql(`SELECT coalesce(metadata->>'steam_id', '-') FROM users WHERE id = '${erinT}'`) === "-");

  // Steam carry-over: a native Steam account (users.steam_id) and no Tretu account yet.
  const dv = await deviceUser("integration-device-dave");
  sql(`UPDATE users SET steam_id = '${STEAM_DAVE}' WHERE id = '${dv.uid}'`);
  await save(dv.token, "slot_0", { farm: "Dave's Dale", player: "Dave", day: 4, saved_at: 10 });
  const d1 = await tretuLogin("tok-dave");
  check("Steam: native Steam account carried over to the Tretu-Konto", d1.status === 200 && claims(d1.json.token).uid === dv.uid
    && sql(`SELECT custom_id || '|' || steam_id || '|' || (metadata->>'steam_id') FROM users WHERE id = '${dv.uid}'`)
      === `tretu:${SUB_DAVE}|${STEAM_DAVE}|${STEAM_DAVE}`, d1);
  const dch = await rpc(d1.json.token, "tretu_farm_choice", {});
  check("Steam: nothing to choose after a carry-over", dch.json.pending === false && dch.json.options?.length === 1, dch);
  const aliceMeta = sql(`SELECT metadata::text FROM users WHERE custom_id = 'tretu:${SUB_ALICE}'`);
  check("no steam_id on accounts without Steam", !aliceMeta.includes("steam_id"), aliceMeta);

  // Purge: archives past 90 days can be removed by the operator (HTTP key), never by players.
  const nope = await rpc(st, "tretu_archive_purge", {});
  check("players cannot purge archives", nope.status === 403 || nope.status === 401, nope);
  const none = await serverRpc("tretu_archive_purge", {});
  check("purge keeps archives younger than 90 days", none.status === 200 && none.json.deleted === 0
    && sql(`SELECT count(*) FROM users WHERE id = '${cd.uid}'`) === "1", none);
  sql(`UPDATE storage SET value = jsonb_set(value, '{at}', to_jsonb(extract(epoch FROM now() - interval '91 days')::bigint)) WHERE collection = 'tretu_archive' AND key = '${cd.uid}'`);
  const purged = await serverRpc("tretu_archive_purge", {});
  check("purge removes archives older than 90 days", purged.status === 200 && purged.json.deleted === 1
    && sql(`SELECT count(*) FROM users WHERE id = '${cd.uid}'`) === "0"
    && sql(`SELECT count(*) FROM users WHERE id = '${es.uid}'`) === "1", purged);
  check("every platform request was correctly signed", received.every((r) => r.ok), received.filter((r) => !r.ok));
  const logText = nakamaLog.join("");
  check("Nakama log has no app secret, access token or signature", !logText.includes(SECRET)
    && !/tok-(alice|bobby|carol|dave|erin|ghost)/.test(logText) && !/v1=[0-9a-f]{64}/.test(logText));

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
