#!/usr/bin/env node
// Runs the Hollowmere Nakama server without Docker (PM2 "hollowmere-nakama" via nakama.sh).
//
//   node server/nakama/run.mjs start     migrate the database, then run Nakama (PM2 uses this)
//   node server/nakama/run.mjs migrate   only "nakama migrate up" (deploy step)
//   node server/nakama/run.mjs check     load the Lua modules once and exit (CI / before a reload)
//   node server/nakama/run.mjs args      print the (redacted) command line start would use
//
// Secrets and the Tretu settings come from the environment (PM2 passes server/.env, see
// ecosystem.config.cjs; a manual run reads server/.env itself) and reach Nakama as command-line
// flags: nothing is written to a file. Every logged command line has the secret values replaced
// by "***".
//
//   Nakama keys        NAKAMA_HTTP_KEY, NAKAMA_SESSION_ENCRYPTION_KEY, NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY,
//                      NAKAMA_CONSOLE_USERNAME, NAKAMA_CONSOLE_PASSWORD, NAKAMA_CONSOLE_SIGNING_KEY
//   Database           NAKAMA_DATABASE_ADDRESS  user:password@host:port/db (or database.address in local.yml)
//   runtime.env        TRETU_AUTH_ISSUER (required), TRETU_PLATFORM_URL, TRETU_APP_ID, TRETU_APP_SECRET,
//                      HOLLOWMERE_PUBLIC_URL, TRETU_PLATFORM_BACKOFF_SEC
//   Other              NAKAMA_BIN (default /opt/nakama/nakama, else nakama on PATH),
//                      NAKAMA_LOCAL_CONFIG (optional extra YAML, default server/nakama/local.yml),
//                      NAKAMA_DATA_DIR (default server/nakama/data), NAKAMA_ENV_FILE (default server/.env;
//                      values already in the environment win)
//   NAKAMA_ALLOW_DEFAULTS=1  dev/CI only: start with Nakama's default keys and without the Tretu
//                      sign-in (only guest play works). Without it the runner refuses to start when a
//                      key above is missing or still a default / CHANGE_ME value.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, accessSync, constants } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** Nakama keys taken from the environment: env name -> Nakama flag. */
export const KEY_FLAGS = {
  NAKAMA_HTTP_KEY: "runtime.http_key",
  NAKAMA_SESSION_ENCRYPTION_KEY: "session.encryption_key",
  NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY: "session.refresh_encryption_key",
  NAKAMA_CONSOLE_USERNAME: "console.username",
  NAKAMA_CONSOLE_PASSWORD: "console.password",
  NAKAMA_CONSOLE_SIGNING_KEY: "console.signing_key",
};
/** Passed to the Lua runtime as runtime.env (tretu.lua reads them from ctx.env). */
export const RUNTIME_ENV_KEYS = ["TRETU_AUTH_ISSUER", "TRETU_PLATFORM_URL", "TRETU_APP_ID", "TRETU_APP_SECRET",
  "HOLLOWMERE_PUBLIC_URL", "TRETU_PLATFORM_BACKOFF_SEC"];
/** Nakama's built-in defaults and the example placeholders: never acceptable in production. */
const DEFAULTS = new Set(["defaulthttpkey", "defaultencryptionkey", "defaultrefreshencryptionkey", "defaultsigningkey",
  "admin", "password", "hollowmere_dev"]);
const SECRET_NAME = /SECRET|PASSWORD|_KEY$|signing_key|encryption_key|http_key/i;

/** Minimal KEY=VALUE reader (same rules as ecosystem.config.cjs). */
export function parseEnvFile(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

/** runtime.env entries ("KEY=value") of a Nakama YAML file, in order. Only that list is read. */
export function yamlRuntimeEnv(text) {
  const out = [];
  let inRuntime = false, inEnv = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+#.*$/, "");
    if (/^\S/.test(line)) { inRuntime = /^runtime:\s*$/.test(line); inEnv = false; continue; }
    if (!inRuntime) continue;
    if (/^ {2}\S/.test(line)) { inEnv = /^ {2}env:\s*$/.test(line); continue; }
    const m = inEnv && line.match(/^\s+-\s*["']?([A-Za-z_][A-Za-z0-9_]*=.*?)["']?\s*$/);
    if (m) out.push(m[1]);
  }
  return out;
}

const isPlaceholder = (v) => /^change[_-]?me/i.test(v) || /CHANGE_ME/.test(v) || DEFAULTS.has(v);

/**
 * Problems that keep the server from starting in production (empty list = fine). `env` is the
 * merged environment, `runtimeEnv` the final runtime.env map.
 */
export function productionProblems(env, runtimeEnv) {
  const problems = [];
  for (const name of Object.keys(KEY_FLAGS)) {
    const v = (env[name] || "").trim();
    if (v === "") problems.push(`${name} is missing`);
    else if (isPlaceholder(v)) problems.push(`${name} is still a default value`);
    else if (name !== "NAKAMA_CONSOLE_USERNAME" && v.length < 16) problems.push(`${name} is too short (16+ characters, e.g. openssl rand -hex 24)`);
  }
  const issuer = runtimeEnv.TRETU_AUTH_ISSUER || "";
  if (!/^https?:\/\/[^\s"]+$/.test(issuer)) problems.push("TRETU_AUTH_ISSUER is missing (Tretu sign-in not configured), e.g. https://auth.tretu.de");
  if (runtimeEnv.TRETU_APP_SECRET && isPlaceholder(runtimeEnv.TRETU_APP_SECRET)) problems.push("TRETU_APP_SECRET is still a default value");
  return problems;
}

/**
 * The Nakama command line for `cmd` ("start" | "migrate"). Returns { args, problems }.
 * runtime.env = hollowmere.yml < local.yml < environment (a flag replaces the YAML list, so the base
 * entries are passed again).
 */
export function buildArgs(cmd, env, { here = HERE, read = (f) => readFileSync(f, "utf8"), exists = existsSync } = {}) {
  const base = path.join(here, "hollowmere.yml");
  const local = env.NAKAMA_LOCAL_CONFIG || path.join(here, "local.yml");
  const args = ["--config", base];
  const runtime = new Map();
  for (const kv of yamlRuntimeEnv(read(base))) runtime.set(kv.slice(0, kv.indexOf("=")), kv.slice(kv.indexOf("=") + 1));
  if (exists(local)) {
    args.push("--config", local);
    for (const kv of yamlRuntimeEnv(read(local))) runtime.set(kv.slice(0, kv.indexOf("=")), kv.slice(kv.indexOf("=") + 1));
  }
  for (const k of RUNTIME_ENV_KEYS) {
    if ((env[k] || "").trim() !== "") runtime.set(k, env[k].trim());
  }
  for (const [name, flag] of Object.entries(KEY_FLAGS)) {
    if ((env[name] || "").trim() !== "") args.push(`--${flag}`, env[name].trim());
  }
  if ((env.NAKAMA_DATABASE_ADDRESS || "").trim() !== "") args.push("--database.address", env.NAKAMA_DATABASE_ADDRESS.trim());
  for (const [k, v] of runtime) args.push("--runtime.env", `${k}=${v}`);
  args.push("--runtime.path", path.join(here, "modules"), "--data_dir", env.NAKAMA_DATA_DIR || path.join(here, "data"));
  const devDefaults = env.NAKAMA_ALLOW_DEFAULTS === "1";
  const problems = devDefaults ? [] : productionProblems(env, Object.fromEntries(runtime));
  return { args: cmd === "migrate" ? ["migrate", "up", ...args] : args, problems, runtime: Object.fromEntries(runtime) };
}

/** The command line with every secret value replaced by *** (for logs). */
export function redact(args) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const flag = /^--(.+)$/.exec(a);
    if (flag && i + 1 < args.length && SECRET_NAME.test(flag[1])) { out.push(a, "***"); i++; continue; }
    if (flag && flag[1] === "database.address" && i + 1 < args.length) { out.push(a, args[i + 1].replace(/^([^:@/]+):[^@]*@/, "$1:***@")); i++; continue; }
    const kv = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(a);
    if (kv && args[i - 1] === "--runtime.env" && SECRET_NAME.test(kv[1])) { out.push(`${kv[1]}=***`); continue; }
    out.push(a);
  }
  return out.join(" ");
}

function findBin(env) {
  const want = env.NAKAMA_BIN || "/opt/nakama/nakama";
  try { accessSync(want, constants.X_OK); return want; } catch { /* not there */ }
  const which = spawnSync("sh", ["-c", "command -v nakama"], { encoding: "utf8" });
  const found = (which.stdout || "").trim();
  if (found) return found;
  throw new Error("nakama binary not found (set NAKAMA_BIN, see HOSTING.md)");
}

function mergedEnv() {
  const file = process.env.NAKAMA_ENV_FILE || path.join(HERE, "..", ".env");
  const fromFile = existsSync(file) ? parseEnvFile(readFileSync(file, "utf8")) : {};
  return { ...fromFile, ...process.env };
}

function runToEnd(bin, args, label) {
  console.log(`nakama ${label}: ${bin} ${redact(args)}`);
  const r = spawnSync(bin, args, { stdio: "inherit" });
  if (r.status !== 0) throw new Error(`nakama ${label} failed (exit ${r.status ?? r.signal})`);
}

function main(argv) {
  const cmd = argv[0] || "start";
  const env = mergedEnv();
  if (cmd === "check") {
    const r = spawnSync(findBin(env), ["check", "--runtime.path", path.join(HERE, "modules")], { stdio: "inherit" });
    process.exit(r.status ?? 1);
  }
  if (!["start", "migrate", "args"].includes(cmd)) {
    console.error("usage: run.mjs start|migrate|check|args");
    process.exit(2);
  }
  const { args, problems } = buildArgs(cmd === "migrate" ? "migrate" : "start", env);
  if (cmd === "args") { console.log(redact(args)); if (problems.length) console.log("problems: " + problems.join("; ")); return; }
  if (problems.length) {
    console.error("nakama: refusing to start: " + problems.join("; ") + ". Put the values in server/.env (HOSTING.md step 5);"
      + " NAKAMA_ALLOW_DEFAULTS=1 is for dev/CI only.");
    process.exit(1);
  }
  const bin = findBin(env);
  runToEnd(bin, cmd === "migrate" ? args : ["migrate", "up", ...args], "migrate");
  if (cmd === "migrate") return;
  const extra = argv.slice(1);
  const full = [...args, ...extra];
  console.log(`nakama start: ${bin} ${redact(full)}`);
  const child = spawn(bin, full, { stdio: "inherit" });
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => child.kill(sig));
  child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (e) { console.error("nakama: " + e.message); process.exit(1); }
}
