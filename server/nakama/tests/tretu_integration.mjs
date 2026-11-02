#!/usr/bin/env node
// End-to-end test of the Tretu integration on a real Nakama + Postgres, no Docker:
// a fake OIDC issuer and a fake platform (both on 127.0.0.1) check what Nakama does:
// sign-in (Tretu-Konto only: the removed email/Google/Apple/Discord sign-ins are refused), carry-over
// of old accounts (legacy_ids.hollowmere first, then Discord/Steam), "Save to Tretu-Konto" from a
// guest (LinkCustom), platform events, the in-game wallet/notification summary,
// choosing a farm when two accounts exist (archive, restore, atomicity, idempotency), purge,
// the platform webhook through the MCP relay (deletion, merge, account lock from the central Tretu admin).
//
//   NAKAMA_BIN=/opt/nakama/nakama node server/nakama/tests/tretu_integration.mjs
//
// Env: NAKAMA_BIN (binary), TEST_DB (default postgres@127.0.0.1:5432/nakama_test; the database is
// dropped and recreated, so never point this at real data), PSQL (default psql),
// GODOT (Godot 4.7 binary: also runs the game client against this server,
// game/tests/net/tretu_client_test.tscn; skipped with a notice when unset), SHOTS (optional
// directory for client screenshots when Godot runs with a display).
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
const SUB_GINA = "61616161-0000-4000-8000-0000000061a1";
const SUB_HANK = "4a4a4a4a-0000-4000-8000-0000000004a1";
const SUB_DAVE_NEW = "d0d0d0d0-0000-4000-8000-00000000da02";
const SUB_LENA = "1e4a1e4a-0000-4000-8000-0000000001e4";
const SUB_LOST = "10511051-0000-4000-8000-000000001051";
const SUB_IVY = "1e1e1e1e-0000-4000-8000-0000000001e1";
const SUB_JO = "10101010-0000-4000-8000-000000000101";
const SUB_KIM = "c1c1c1c1-0000-4000-8000-00000000c1c1";
const SUB_MAX = "3a3a3a3a-0000-4000-8000-0000000003a3";
const SUB_NED = "4e4e4e4e-0000-4000-8000-0000000004e4";
const SUB_OLGA = "0a0a0a0a-0000-4000-8000-000000000a1a";
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
  "tok-gina": { sub: SUB_GINA, preferred_username: "gina" },
  "tok-hank": { sub: SUB_HANK, preferred_username: "hank" },
  "tok-dave-new": { sub: SUB_DAVE_NEW, preferred_username: "dave" },
  "tok-lena": { sub: SUB_LENA, preferred_username: "lena" },
  "tok-lost": { sub: SUB_LOST, preferred_username: "lost" },
  "tok-ivy-old": { sub: SUB_IVY, preferred_username: "ivy" },
  "tok-jo-legacy": { sub: SUB_JO, preferred_username: "jo" },
  "tok-kim-guest": { sub: SUB_KIM, preferred_username: "kim" },
  "tok-max-guest": { sub: SUB_MAX, preferred_username: "max" },
  "tok-ned-other": { sub: SUB_NED, preferred_username: "ned" },
  "tok-olga-guest": { sub: SUB_OLGA, preferred_username: "olga" },
};
const received = [];
const lockedAtIssuer = new Set();
let platformDown = false;
let platformHang = false;
const wallets = { [SUB_ALICE]: 120, [SUB_BOB]: 7, [SUB_GINA]: 4321 };
const unread = { [SUB_ALICE]: 3, [SUB_GINA]: 2 };
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
      // Like auth.tretu.de: a locked account gets no answer (its tokens are revoked).
      return users[tok] && !lockedAtIssuer.has(users[tok].sub) ? send(200, users[tok]) : send(401, { error: "invalid_token" });
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
// "Save to Tretu-Konto": a signed-in guest links its own account (what Net.login_tretu does first).
const tretuLink = (session, token) => api("POST", "/v2/account/link/custom", { session, body: { id: "tretu-link", vars: { tretu_token: token } } });
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

  // --- Tretu-Konto only: the removed sign-ins are refused by the server ---------------------------
  const users1 = sql("SELECT count(*) FROM users");
  const viaEmail = await api("POST", "/v2/account/authenticate/email?create=true", { basic: true, body: { email: "new@hollowmere.test", password: "password123" } });
  check("email sign-up refused", viaEmail.status === 400 && /no longer available/.test(JSON.stringify(viaEmail.json)), viaEmail);
  const viaGoogle = await api("POST", "/v2/account/authenticate/google?create=true", { basic: true, body: { token: "fake-google-id-token" } });
  check("Google sign-in refused", viaGoogle.status === 400 && /no longer available/.test(JSON.stringify(viaGoogle.json)), viaGoogle);
  const viaApple = await api("POST", "/v2/account/authenticate/apple?create=true", { basic: true, body: { token: "fake-apple-id-token" } });
  check("Apple sign-in refused", viaApple.status === 400 && /no longer available/.test(JSON.stringify(viaApple.json)), viaApple);
  const viaDiscord = await api("POST", "/v2/account/authenticate/custom?create=true", { basic: true, body: { id: "discord", vars: { discord_token: "x" } } });
  check("Discord sign-in refused (no request to Discord)", viaDiscord.status === 400 && /Tretu/.test(JSON.stringify(viaDiscord.json)), viaDiscord);
  const g0 = await deviceUser("integration-device-refuse");
  const linkEmail = await api("POST", "/v2/account/link/email", { session: g0.token, body: { email: "g@hollowmere.test", password: "password123" } });
  check("adding an email to a guest refused", linkEmail.status === 400, linkEmail);
  const unlinkT = await api("POST", "/v2/account/unlink/custom", { session: a1.json.token, body: { id: `tretu:${SUB_ALICE}` } });
  check("removing the Tretu link refused", unlinkT.status === 400
    && sql(`SELECT custom_id FROM users WHERE id = '${discordUser}'`) === `tretu:${SUB_ALICE}`, unlinkT);
  check("no account created by a refused sign-in", sql("SELECT count(*) FROM users") === String(Number(users1) + 1));

  // --- Old accounts carried over on the first Tretu login: legacy_ids.hollowmere first -------------
  // An email account (from the legacy import: the auth server's legacy_ids.hollowmere = its user id).
  const iv = await deviceUser("integration-device-ivy");
  sql(`UPDATE users SET email = 'ivy@hollowmere.test', password = 'x' WHERE id = '${iv.uid}'`);
  sql(`DELETE FROM user_device WHERE user_id = '${iv.uid}'`);
  await save(iv.token, "slot_0", { farm: "Ivy Glade", player: "Ivy", day: 40, saved_at: 100 });
  users["tok-ivy-old"].legacy_ids = { hollowmere: iv.uid.toUpperCase(), saga: "17" };
  const ivy = await tretuLogin("tok-ivy-old");
  check("legacy_ids: the old email account becomes the Tretu farm", ivy.status === 200 && claims(ivy.json.token).uid === iv.uid
    && sql(`SELECT custom_id FROM users WHERE id = '${iv.uid}'`) === `tretu:${SUB_IVY}`, ivy.json);
  const ivySaves = await api("GET", `/v2/storage/saves/${iv.uid}?limit=10`, { session: ivy.json.token });
  check("legacy_ids: its cloud save is there", (ivySaves.json.objects || []).some((o) => o.key === "slot_0"), ivySaves.json);
  const ivyCh = await rpc(ivy.json.token, "tretu_farm_choice", {});
  check("legacy_ids: nothing to choose afterwards", ivyCh.json.pending === false && ivyCh.json.options?.length === 1, ivyCh);
  // legacy_ids wins over the Discord claim; the Discord account waits in the farm choice (never merged).
  const joOld = await deviceUser("integration-device-jo-old");
  await save(joOld.token, "slot_0", { farm: "Jo Old", player: "Jo", day: 12, saved_at: 10 });
  const joDc = await deviceUser("integration-device-jo-discord");
  sql(`UPDATE users SET custom_id = 'discord:888000888' WHERE id = '${joDc.uid}'`);
  await save(joDc.token, "slot_1", { farm: "Jo Discord", player: "Jo", day: 3, saved_at: 20 });
  users["tok-jo-legacy"].legacy_ids = { hollowmere: joOld.uid };
  users["tok-jo-legacy"].discord_id = "888000888";
  const jo = await tretuLogin("tok-jo-legacy");
  check("legacy_ids before discord_id", jo.status === 200 && claims(jo.json.token).uid === joOld.uid
    && sql(`SELECT custom_id FROM users WHERE id = '${joDc.uid}'`) === "discord:888000888", jo.json);
  const joCh = await rpc(jo.json.token, "tretu_farm_choice", {});
  check("the Discord account is offered in the farm choice", joCh.json.pending === true
    && (joCh.json.options || []).some((o) => o.id === joDc.uid && o.kind === "discord" && o.saves?.[0]?.farm === "Jo Discord"), joCh);
  // legacy_ids pointing at an account that already belongs to another Tretu-Konto: never taken.
  users["tok-ned-other"].legacy_ids = { hollowmere: iv.uid };
  const ned = await tretuLogin("tok-ned-other");
  check("legacy_ids: an account linked to another Tretu-Konto is never re-keyed", ned.status === 200 && claims(ned.json.token).uid !== iv.uid
    && sql(`SELECT custom_id FROM users WHERE id = '${iv.uid}'`) === `tretu:${SUB_IVY}`, ned.json);
  const nedCh = await rpc(ned.json.token, "tretu_farm_choice", {});
  check("…and not offered to the other player either", nedCh.json.pending === false && !(nedCh.json.options || []).some((o) => o.id === iv.uid), nedCh);
  users["tok-ned-other"].legacy_ids = { hollowmere: "not-a-uuid'); DROP TABLE users; --" };
  check("legacy_ids: a malformed id is ignored", (await tretuLogin("tok-ned-other")).status === 200 && sql("SELECT count(*) FROM users") !== "0");

  // --- "Save to Tretu-Konto": a guest keeps its farm ------------------------------------------------
  const kg = await deviceUser("integration-device-kim");
  await save(kg.token, "slot_0", { farm: "Kim Meadow", player: "Kim", day: 7, saved_at: 70 });
  const badLink = await tretuLink(kg.token, "tok-nobody");
  check("guest upgrade: an unknown token is refused, the guest stays a guest", badLink.status === 401
    && sql(`SELECT coalesce(custom_id, '-') FROM users WHERE id = '${kg.uid}'`) === "-", badLink);
  const kl = await tretuLink(kg.token, "tok-kim-guest");
  check("guest upgrade: linked", kl.status === 200 && sql(`SELECT custom_id FROM users WHERE id = '${kg.uid}'`) === `tretu:${SUB_KIM}`, kl);
  const kim = await tretuLogin("tok-kim-guest");
  check("guest upgrade: the Tretu sign-in lands on the guest's farm", kim.status === 200 && claims(kim.json.token).uid === kg.uid
    && claims(kim.json.token).vrs?.tretu_sub === SUB_KIM, kim.json);
  const kimSaves = await api("GET", `/v2/storage/saves/${kg.uid}?limit=10`, { session: kim.json.token });
  check("guest upgrade: the guest's cloud save is kept", (kimSaves.json.objects || []).some((o) => o.key === "slot_0"), kimSaves.json);
  check("guest upgrade: tretu_username on the metadata", sql(`SELECT metadata->>'tretu_username' FROM users WHERE id = '${kg.uid}'`) === "kim");
  const kim2 = await tretuLink(kg.token, "tok-kim-guest");
  check("guest upgrade: linking again is harmless", kim2.status === 200 && sql(`SELECT count(*) FROM users WHERE custom_id = 'tretu:${SUB_KIM}'`) === "1", kim2);
  // A second guest of the same Tretu-Konto: the Tretu-Konto already has a farm -> AlreadyExists (the game signs in normally).
  const kg2 = await deviceUser("integration-device-kim-2");
  const taken = await tretuLink(kg2.token, "tok-kim-guest");
  check("guest upgrade: Tretu-Konto already has a farm -> 409, nothing changed", taken.status === 409
    && sql(`SELECT coalesce(custom_id, '-') FROM users WHERE id = '${kg2.uid}'`) === "-" && sql(`SELECT custom_id FROM users WHERE id = '${kg.uid}'`) === `tretu:${SUB_KIM}`, taken);
  const other = await tretuLink(kim.json.token, "tok-ivy-old");
  check("guest upgrade: a farm of another Tretu-Konto is never moved", other.status === 400
    && sql(`SELECT custom_id FROM users WHERE id = '${kg.uid}'`) === `tretu:${SUB_KIM}`, other);
  // Guest upgrade while legacy_ids names an old account: the guest's farm is kept, the old one is offered.
  const mxOld = await deviceUser("integration-device-max-old");
  sql(`UPDATE users SET email = 'max@hollowmere.test', password = 'x' WHERE id = '${mxOld.uid}'`);
  await save(mxOld.token, "slot_0", { farm: "Max Old", player: "Max", day: 30, saved_at: 5 });
  users["tok-max-guest"].legacy_ids = { hollowmere: mxOld.uid };
  const mxGuest = await deviceUser("integration-device-max-guest");
  check("guest upgrade with an old account: linked", (await tretuLink(mxGuest.token, "tok-max-guest")).status === 200);
  const mx = await tretuLogin("tok-max-guest");
  check("…the Tretu farm is the guest's", claims(mx.json.token).uid === mxGuest.uid && sql(`SELECT email FROM users WHERE id = '${mxOld.uid}'`) === "max@hollowmere.test");
  const mxCh = await rpc(mx.json.token, "tretu_farm_choice", {});
  check("…and the old Hollowmere account waits in the farm choice", mxCh.json.pending === true
    && (mxCh.json.options || []).some((o) => o.id === mxOld.uid && o.kind === "hollowmere" && o.saves?.[0]?.farm === "Max Old"), mxCh);
  const mxKeep = await rpc(mx.json.token, "tretu_farm_choose", { keep: mxOld.uid });
  check("…keeping it re-keys the old account and archives the guest farm", mxKeep.status === 200 && mxKeep.json.changed === true
    && sql(`SELECT custom_id FROM users WHERE id = '${mxOld.uid}'`) === `tretu:${SUB_MAX}`
    && sql(`SELECT custom_id FROM users WHERE id = '${mxGuest.uid}'`) === `archived:${mxGuest.uid}`, mxKeep);

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
    && sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_archive' AND value->>'sub' = '${SUB_CAROL}'`) === "0");
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
  // The real game client (Net, Tretu, TretuMenu, FarmChoicePanel) against this server.
  if (process.env.GODOT) {
    const gt = await tretuLogin("tok-gina");
    const ginaT = claims(gt.json.token).uid;
    await save(gt.json.token, "slot_0", { farm: "Gina New", player: "Gina", day: 1, saved_at: 5 });
    const gd = await deviceUser("integration-device-gina");
    sql(`UPDATE users SET custom_id = 'discord:777000777' WHERE id = '${gd.uid}'`);
    await save(gd.token, "slot_1", { farm: "Gina's Old Grove", player: "Gina", day: 61, money: 777, saved_at: 50 });
    users["tok-gina"].discord_id = "777000777";
    const args = ["--path", path.join(repo, "game"), "res://tests/net/tretu_client_test.tscn", "--",
      "--port=17350", `--issuer=${FAKE}`, "--token=tok-gina", `--discord-user=${gd.uid}`, "--guest-token=tok-olga-guest"];
    if (process.env.SHOTS) args.push(`--shots=${process.env.SHOTS}`);
    else args.unshift("--headless");
    const out = await new Promise((resolve) => {
      const p = spawn(process.env.GODOT, args, { stdio: ["ignore", "pipe", "pipe"] });
      let text = "";
      p.stdout.on("data", (d) => (text += d));
      p.stderr.on("data", (d) => (text += d));
      const kill = setTimeout(() => p.kill("SIGKILL"), 300000); // slow machines: generous
      p.on("close", () => { clearTimeout(kill); resolve(text); });
    });
    // Godot 4.7 can abort while tearing down after a clean quit (tools/ci/godot.sh): judge by output.
    check("game client: Tretu menu and farm choice end to end", out.includes("TRETU CLIENT TEST DONE, 0 failures"),
      out.split("\n").filter((l) => /FAIL|ERROR|DONE/.test(l)).slice(0, 20));
    check("game client left the first farm active", sql(`SELECT custom_id FROM users WHERE id = '${ginaT}'`) === `tretu:${SUB_GINA}`);
    check("game client: guest upgraded through the account panel", sql(`SELECT count(*) FROM users WHERE custom_id = 'tretu:${SUB_OLGA}'`) === "1"
      && sql(`SELECT count(*) FROM user_device d JOIN users u ON u.id = d.user_id WHERE u.custom_id = 'tretu:${SUB_OLGA}'`) === "1");
  } else {
    console.log("skip game client test (set GODOT=/path/to/godot to run it)");
  }
  check("every platform request was correctly signed", received.every((r) => r.ok), received.filter((r) => !r.ok));
  const logText = nakamaLog.join("");
  check("Nakama log has no app secret, access token or signature", !logText.includes(SECRET)
    && !/tok-(alice|bobby|carol|dave|erin|ghost|ivy|jo|kim|max|ned|olga)/.test(logText) && !/v1=[0-9a-f]{64}/.test(logText));

  // --- Platform webhook through the MCP relay (POST /api/tretu/webhook), and /api/health -----------
  mcp = spawn(process.execPath, [path.join(repo, "server/mcp/server.mjs")], {
    env: { ...process.env, MCP_PORT: "18787", NAKAMA_URL: API, NAKAMA_HTTP_KEY: HTTP_KEY, TRETU_APP_SECRET: SECRET }, stdio: "ignore",
  });
  let health = null;
  for (let i = 0; i < 40 && !health; i++) {
    await sleep(250);
    health = await fetch("http://127.0.0.1:18787/api/health").then(async (r) => ({ status: r.status, body: await r.json() }), () => null);
  }
  check("/api/health ok", health?.status === 200 && health.body.status === "ok" && health.body.app === "hollowmere" && health.body.checks.db === "ok", health);

  const HOOK = "http://127.0.0.1:18787/api/tretu/webhook";
  // What tretu.de's worker sends: x-tretu-app "platform", signed with Hollowmere's own secret.
  const hookReq = (type, sub, data = {}, { ts = Math.floor(Date.now() / 1000), secret = SECRET, app = "platform", at = Date.now() } = {}) => {
    const body = JSON.stringify({ id: crypto.randomUUID(), type, app: "platform", sub, occurredAt: new Date(at).toISOString(), data });
    const base = `${ts}\nPOST\n/api/tretu/webhook\n${sha256(body)}`;
    return { body, headers: { "Content-Type": "application/json", "x-tretu-app": app, "x-tretu-timestamp": String(ts),
      "x-tretu-signature": "v1=" + crypto.createHmac("sha256", secret).update(base).digest("hex") } };
  };
  const post = async (req) => {
    const r = await fetch(HOOK, { method: "POST", headers: req.headers, body: req.body });
    return { status: r.status, text: await r.text() };
  };
  const users0 = sql("SELECT count(*) FROM users");
  const forged = await post(hookReq("user.deleted", SUB_BOB, {}, { secret: "not-the-secret-0123456789abcdef" }));
  check("webhook: forged signature rejected", forged.status === 401 && sql("SELECT count(*) FROM users") === users0, forged);
  const stale = await post(hookReq("user.deleted", SUB_BOB, {}, { ts: Math.floor(Date.now() / 1000) - 400 }));
  check("webhook: replay of an old delivery (timestamp > 300 s) rejected", stale.status === 401 && sql("SELECT count(*) FROM users") === users0, stale);
  const foreign = await post(hookReq("user.deleted", SUB_BOB, {}, { app: "saga" }));
  check("webhook: only the platform may call it", foreign.status === 401, foreign);
  const tampered = hookReq("user.deleted", SUB_ALICE);
  tampered.body = tampered.body.replace(SUB_ALICE, SUB_BOB);
  check("webhook: body is covered by the signature", (await post(tampered)).status === 401);
  check("webhook: GET refused", (await fetch(HOOK)).status === 405);
  check("webhook: unknown types answered 204", (await post(hookReq("badge.earned", SUB_BOB, { badge: "x" }))).status === 204);
  const viaPlayer = await rpc(sb, "tretu_user_deleted", { sub: SUB_BOB });
  check("players cannot call the deletion RPC", viaPlayer.status === 403 && sql(`SELECT count(*) FROM users WHERE custom_id = 'tretu:${SUB_BOB}'`) === "1", viaPlayer);

  // user.updated: username + Steam link refreshed on the account metadata.
  const upd = await post(hookReq("user.updated", SUB_ALICE, { sub: SUB_ALICE, username: "alice_new", links: { discord: "123456789012", steam: "76561198000000077" } }));
  check("webhook: user.updated refreshes username and Steam metadata", upd.status === 200
    && sql(`SELECT (metadata->>'tretu_username') || '|' || (metadata->>'steam_id') FROM users WHERE custom_id = 'tretu:${SUB_ALICE}'`) === "alice_new|76561198000000077", upd);
  const idsBefore = sql("SELECT count(*) FROM storage WHERE collection = 'tretu_identity'");
  await post(hookReq("user.updated", "77777777-0000-4000-8000-000000000777", { username: "never_played" }));
  check("webhook: nothing stored for Tretu users who never played", sql("SELECT count(*) FROM storage WHERE collection = 'tretu_identity'") === idsBefore);

  // user.updated with locked (central Tretu admin): the "tretu:<sub>" account is disabled, its sessions,
  // refresh tokens and sockets end, sign-in is refused; locked: false enables it again. Idempotent, and a
  // late retry of an older lock never undoes a newer unlock.
  const ln = await tretuLogin("tok-lena");
  check("lock: player signed in", ln.status === 200, ln.json);
  const lenaUid = claims(ln.json.token).uid;
  const lenaDisabled = () => sql(`SELECT disable_time > 'epoch' FROM users WHERE id = '${lenaUid}'`) === "t";
  const ws = new WebSocket(`ws://127.0.0.1:17350/ws?lang=en&status=true&token=${encodeURIComponent(ln.json.token)}`);
  const wsClosed = new Promise((resolve) => ws.addEventListener("close", () => resolve(true)));
  const wsOpen = await new Promise((resolve) => { ws.addEventListener("open", () => resolve(true)); ws.addEventListener("error", () => resolve(false)); });
  check("lock: the player has a live socket", wsOpen);
  await sleep(1100); // Nakama ends sessions by "issued before <second>" (see the merge test below)
  const lockAt = Date.now();
  const locked = await post(hookReq("user.updated", SUB_LENA, { sub: SUB_LENA, username: "lena", locked: true }, { at: lockAt }));
  check("lock: webhook accepted, account disabled", locked.status === 200 && lenaDisabled(), locked);
  check("lock: the socket is closed", await Promise.race([wsClosed, sleep(5000).then(() => false)]));
  check("lock: the old session no longer works", (await rpc(ln.json.token, "tretu_heartbeat", {})).status === 401);
  const refresh = await api("POST", "/v2/account/session/refresh", { basic: true, body: { token: ln.json.refresh_token } });
  check("lock: the refresh token is refused", refresh.status >= 400 && refresh.status < 500, refresh);
  lockedAtIssuer.add(SUB_LENA);
  const issuerRefused = await tretuLogin("tok-lena");
  check("lock: auth.tretu.de refuses the locked account, so does the sign-in", issuerRefused.status === 401 && lenaDisabled(), issuerRefused);
  lockedAtIssuer.delete(SUB_LENA);
  // A lock recorded after auth.tretu.de answered (an overlapping lock) still refuses, with a clear message.
  await post(hookReq("user.updated", SUB_LENA, { sub: SUB_LENA, locked: true }, { at: Date.now() + 600_000 }));
  const lockedLogin = await tretuLogin("tok-lena");
  check("lock: Tretu sign-in refused with a clear message", lockedLogin.status === 403 && /locked/i.test(JSON.stringify(lockedLogin.json)) && lenaDisabled(), lockedLogin);
  const lockAgain = await post(hookReq("user.updated", SUB_LENA, { sub: SUB_LENA, locked: true }, { at: lockAt + 600_000 }));
  check("lock: a repeated delivery is harmless", lockAgain.status === 200 && lenaDisabled(), lockAgain);
  const unlocked = await post(hookReq("user.updated", SUB_LENA, { sub: SUB_LENA, locked: false }, { at: lockAt + 602_000 }));
  check("unlock: account enabled again", unlocked.status === 200 && !lenaDisabled(), unlocked);
  const lateLock = await post(hookReq("user.updated", SUB_LENA, { sub: SUB_LENA, locked: true }, { at: lockAt + 601_000 }));
  check("unlock: a late retry of an older lock changes nothing", lateLock.status === 200 && !lenaDisabled(), lateLock);
  const back = await tretuLogin("tok-lena");
  check("unlock: the player signs into the same farm again", back.status === 200 && claims(back.json.token).uid === lenaUid, back.json);
  check("unlock: sessions from before the lock stay ended", (await rpc(ln.json.token, "tretu_heartbeat", {})).status === 401);
  check("unlock: the new session works", (await rpc(back.json.token, "tretu_heartbeat", {})).status === 200);

  // The unlock webhook got lost: auth.tretu.de answering the sign-in proves the unlock, the lock (recorded before)
  // and its ban are lifted, and the player signs into the same farm.
  const lo = await tretuLogin("tok-lost");
  const lostUid = claims(lo.json.token).uid;
  const lostDisabled = () => sql(`SELECT disable_time > 'epoch' FROM users WHERE id = '${lostUid}'`) === "t";
  await sleep(1100);
  const lostAt = Date.now();
  await post(hookReq("user.updated", SUB_LOST, { sub: SUB_LOST, locked: true }, { at: lostAt }));
  check("lost unlock: locked and disabled", lostDisabled() && (await rpc(lo.json.token, "tretu_heartbeat", {})).status === 401);
  await sleep(50);
  const lostBack = await tretuLogin("tok-lost");
  check("lost unlock: a successful Tretu sign-in lifts the lock", lostBack.status === 200 && claims(lostBack.json.token).uid === lostUid && !lostDisabled()
    && sql(`SELECT value->>'locked' FROM storage WHERE collection = 'tretu_locks' AND key = '${SUB_LOST}'`) === "false", lostBack.json);
  const retryOld = await post(hookReq("user.updated", SUB_LOST, { sub: SUB_LOST, locked: true }, { at: lostAt }));
  check("lost unlock: a late retry of that lock changes nothing", retryOld.status === 200 && !lostDisabled(), retryOld);

  // user.deleted: Bob's account, saves, outbox, identity, co-op codes and AI-helper tokens are gone.
  const bobUid = claims(sb).uid;
  await save(sb, "slot_0", { farm: "Bob Farm", day: 2 });
  const bobTok = await rpc(sb, "agent_issue_token", { name: "helper" });
  await rpc(sb, "create_coop_code", { match_id: "integration-match-bob-0002" });
  const del = hookReq("user.deleted", SUB_BOB, {});
  const gone = await post(del);
  check("webhook: user.deleted accepted", gone.status === 200, gone);
  check("deleted: account and its storage are gone",
    sql(`SELECT count(*) FROM users WHERE id = '${bobUid}'`) === "0" && sql(`SELECT count(*) FROM storage WHERE user_id = '${bobUid}'`) === "0");
  check("deleted: identity, AI-helper token and co-op code are gone",
    sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_identity' AND key = '${SUB_BOB}'`) === "0"
    && sql(`SELECT count(*) FROM storage WHERE collection = 'agent_tokens' AND value->>'user' = '${bobUid}'`) === "0"
    && sql(`SELECT count(*) FROM storage WHERE collection = 'coop_codes' AND value->>'host' = '${bobUid}'`) === "0", bobTok);
  check("deleted: the old session no longer works", (await rpc(sb, "tretu_heartbeat", {})).status === 401);
  const again2 = await post(del);
  check("deleted: a repeated delivery is harmless (idempotent)", again2.status === 200 && sql("SELECT count(*) FROM users WHERE custom_id LIKE 'tretu:%'") !== "0", again2);
  check("deleted: other players untouched", sql(`SELECT count(*) FROM users WHERE custom_id = 'tretu:${SUB_ALICE}'`) === "1");

  // user.deleted for a player with an archived farm: both accounts and the archive record go.
  const erinIds = sql(`SELECT string_agg(key, ',') FROM storage WHERE collection = 'tretu_archive' AND value->>'sub' = '${SUB_ERIN}'`);
  check("Erin has an archived farm before deletion", erinIds !== "", erinIds);
  check("webhook: Erin deleted", (await post(hookReq("user.deleted", SUB_ERIN))).status === 200);
  check("deleted: archived farms of that sub and their records are gone too",
    sql(`SELECT count(*) FROM users WHERE id::text IN ('${erinIds.split(",").join("','")}') OR custom_id = 'tretu:${SUB_ERIN}'`) === "0"
    && sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_archive' AND value->>'sub' = '${SUB_ERIN}'`) === "0"
    && sql(`SELECT count(*) FROM storage WHERE collection = 'tretu_links' AND value->>'custom_id' = 'tretu:${SUB_ERIN}'`) === "0");

  // Merge, surviving sub has no Hollowmere account yet: the farm is re-keyed to it.
  const daveUid = sql(`SELECT id FROM users WHERE custom_id = 'tretu:${SUB_DAVE}'`);
  const daveSession = (await tretuLogin("tok-dave")).json.token;
  // Nakama ends sessions by "issued before <second>": a token from the very same second survives.
  // Real sessions are older; make this one at least a second old.
  await sleep(1100);
  const m1 = await post(hookReq("user.deleted", SUB_DAVE, { mergedInto: SUB_DAVE_NEW }));
  check("merge: farm re-keyed to the surviving Tretu-Konto", m1.status === 200
    && sql(`SELECT custom_id || '|' || (disable_time > 'epoch') FROM users WHERE id = '${daveUid}'`) === `tretu:${SUB_DAVE_NEW}|false`, m1);
  check("merge: old session (old sub) ended", (await rpc(daveSession, "tretu_heartbeat", {})).status === 401);
  const dn = await tretuLogin("tok-dave-new");
  check("merge: surviving Tretu-Konto signs into that farm", dn.status === 200 && claims(dn.json.token).uid === daveUid, dn);
  const m1b = await post(hookReq("user.deleted", SUB_DAVE, { mergedInto: SUB_DAVE_NEW }));
  check("merge: repeated delivery changes nothing", m1b.status === 200 && sql(`SELECT custom_id FROM users WHERE id = '${daveUid}'`) === `tretu:${SUB_DAVE_NEW}`);

  // Merge into a Tretu-Konto that already has a farm: the old farm waits in its archived farms.
  const hk = await tretuLogin("tok-hank");
  const hankUid = claims(hk.json.token).uid;
  const aliceUid = sql(`SELECT id FROM users WHERE custom_id = 'tretu:${SUB_ALICE}'`);
  const m2 = await post(hookReq("user.deleted", SUB_ALICE, { mergedInto: SUB_HANK }));
  check("merge into an existing farm: old farm archived under the survivor", m2.status === 200
    && sql(`SELECT custom_id || '|' || (disable_time > 'epoch') FROM users WHERE id = '${aliceUid}'`) === `archived:${aliceUid}|true`
    && sql(`SELECT value->>'sub' FROM storage WHERE collection = 'tretu_archive' AND key = '${aliceUid}'`) === SUB_HANK, m2);
  const hch = await rpc(hk.json.token, "tretu_farm_choice", {});
  const offered = (hch.json.options || []).find((o) => o.id === aliceUid);
  check("merge: the survivor can restore it in the farm choice", offered?.kind === "archived" && offered.saves?.some((x) => x.farm === "Moss"), hch);
  const restoredA = await rpc(hk.json.token, "tretu_farm_choose", { keep: aliceUid });
  check("merge: restoring it gives a refreshable session through the switch ticket", restoredA.status === 200 && /^[0-9a-f]{64}$/.test(restoredA.json.switch || ""), restoredA);
  const sw = await api("POST", "/v2/account/authenticate/custom?create=false", { basic: true, body: { id: "tretu-switch", vars: { tretu_switch: restoredA.json.switch } } });
  check("switch ticket signs into the kept farm with a refresh token", sw.status === 200 && claims(sw.json.token).uid === aliceUid
    && claims(sw.json.token).vrs?.tretu_sub === SUB_HANK && typeof sw.json.refresh_token === "string" && sw.json.refresh_token.length > 20, sw);
  const sw2 = await api("POST", "/v2/account/authenticate/custom?create=false", { basic: true, body: { id: "tretu-switch", vars: { tretu_switch: restoredA.json.switch } } });
  check("switch ticket is single use", sw2.status === 401, sw2);
  const swBad = await api("POST", "/v2/account/authenticate/custom?create=false", { basic: true, body: { id: "tretu-switch", vars: { tretu_switch: "0".repeat(64) } } });
  check("unknown switch ticket refused", swBad.status === 401, swBad);
} catch (e) {
  failures++;
  console.log("FAIL exception", e?.stack || e);
} finally {
  cleanup();
}
// On failure, the end of Nakama's log (it never contains the secret or tokens: checked above).
if (failures) console.log("--- nakama log (tail) ---\n" + nakamaLog.join("").slice(-6000));
console.log(`TRETU INTEGRATION DONE, ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
