// Unit tests for server/nakama/run.mjs: Nakama command line from the environment, production
// checks, redaction of secrets in logged command lines.
//   node --test server/nakama/tests/run_test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { buildArgs, redact, parseEnvFile, yamlRuntimeEnv, productionProblems, KEY_FLAGS } from "../run.mjs";

const here = path.resolve(import.meta.dirname, "..");
const SECRET = "app-secret-0123456789abcdef0123";
const good = {
  NAKAMA_HTTP_KEY: "httpkey-0123456789abcdef",
  NAKAMA_SESSION_ENCRYPTION_KEY: "sessionkey-0123456789abcdef",
  NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY: "refreshkey-0123456789abcdef",
  NAKAMA_CONSOLE_USERNAME: "hm-ops",
  NAKAMA_CONSOLE_PASSWORD: "console-password-0123456789",
  NAKAMA_CONSOLE_SIGNING_KEY: "signingkey-0123456789abcdef",
  NAKAMA_DATABASE_ADDRESS: "nakama:db-pass-0123@127.0.0.1:5432/nakama",
  TRETU_AUTH_ISSUER: "https://auth.tretu.de",
  TRETU_PLATFORM_URL: "https://tretu.de",
  TRETU_APP_ID: "hollowmere",
  TRETU_APP_SECRET: SECRET,
  HOLLOWMERE_PUBLIC_URL: "https://hollowmere.tretu.de",
  TRETU_PLATFORM_BACKOFF_SEC: "15",
  NAKAMA_LOCAL_CONFIG: "/nonexistent/local.yml",
  NAKAMA_DATA_DIR: "/tmp/hm-data",
};
const flag = (args, name) => args[args.indexOf("--" + name) + 1];
const runtimeEnv = (args) => args.filter((_, i) => args[i - 1] === "--runtime.env");

test("production: keys and Tretu settings become flags, base runtime.env kept", () => {
  const { args, problems } = buildArgs("start", good, { here });
  assert.deepEqual(problems, []);
  assert.equal(args[0], "--config"); assert.equal(args[1], path.join(here, "hollowmere.yml"));
  assert.ok(!args.includes("/nonexistent/local.yml"), "missing local.yml is skipped");
  for (const [name, f] of Object.entries(KEY_FLAGS)) assert.equal(flag(args, f), good[name], f);
  assert.equal(flag(args, "database.address"), good.NAKAMA_DATABASE_ADDRESS);
  const rt = runtimeEnv(args);
  for (const k of ["TRETU_AUTH_ISSUER", "TRETU_PLATFORM_URL", "TRETU_APP_ID", "TRETU_APP_SECRET", "HOLLOWMERE_PUBLIC_URL", "TRETU_PLATFORM_BACKOFF_SEC"]) {
    assert.ok(rt.includes(`${k}=${good[k]}`), k);
  }
  // The flag replaces the YAML list: hollowmere.yml's own entries must be passed again.
  assert.ok(rt.includes("max_save_bytes=3145728") && rt.includes("max_profile_bytes=65536") && rt.includes("code_ttl_sec=43200"), rt.join(" "));
  assert.equal(flag(args, "runtime.path"), path.join(here, "modules"));
  assert.equal(flag(args, "data_dir"), "/tmp/hm-data");
  const m = buildArgs("migrate", good, { here }).args;
  assert.deepEqual(m.slice(0, 2), ["migrate", "up"]);
});

test("local.yml (compat): its runtime.env is merged, the environment wins", () => {
  const files = {
    [path.join(here, "hollowmere.yml")]: 'runtime:\n  env:\n    - "max_save_bytes=1"\n',
    "/srv/local.yml": 'database:\n  address:\n    - "x"\nruntime:\n  http_key: "k"\n  env:\n    - "TRETU_AUTH_ISSUER=https://old.example" # old\n    - "HOLLOWMERE_PUBLIC_URL=https://hm.example"\nconsole:\n  username: "u"\n',
  };
  const env = { ...good, NAKAMA_LOCAL_CONFIG: "/srv/local.yml", HOLLOWMERE_PUBLIC_URL: "" };
  const { args, runtime } = buildArgs("start", env, { here, read: (f) => files[f], exists: (f) => f in files });
  assert.deepEqual(args.slice(0, 4), ["--config", path.join(here, "hollowmere.yml"), "--config", "/srv/local.yml"]);
  assert.equal(runtime.TRETU_AUTH_ISSUER, "https://auth.tretu.de", "environment wins");
  assert.equal(runtime.HOLLOWMERE_PUBLIC_URL, "https://hm.example", "local.yml value kept when the env is empty");
  assert.equal(runtime.max_save_bytes, "1");
});

test("production refuses missing, default or placeholder keys and a missing Tretu issuer", () => {
  const p = (over) => buildArgs("start", { ...good, ...over }, { here }).problems.join("; ");
  assert.match(p({ NAKAMA_CONSOLE_PASSWORD: "" }), /NAKAMA_CONSOLE_PASSWORD is missing/);
  assert.match(p({ NAKAMA_CONSOLE_PASSWORD: "password" }), /NAKAMA_CONSOLE_PASSWORD is still a default/);
  assert.match(p({ NAKAMA_CONSOLE_USERNAME: "admin" }), /NAKAMA_CONSOLE_USERNAME is still a default/);
  assert.match(p({ NAKAMA_CONSOLE_SIGNING_KEY: "defaultsigningkey" }), /SIGNING_KEY is still a default/);
  assert.match(p({ NAKAMA_HTTP_KEY: "change-me-http-key" }), /NAKAMA_HTTP_KEY is still a default/);
  assert.match(p({ NAKAMA_SESSION_ENCRYPTION_KEY: "CHANGE_ME_SESSION_KEY" }), /SESSION_ENCRYPTION_KEY is still a default/);
  assert.match(p({ NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY: "short" }), /too short/);
  assert.match(p({ TRETU_AUTH_ISSUER: "" }), /TRETU_AUTH_ISSUER is missing/);
  assert.match(p({ TRETU_APP_SECRET: "CHANGE_ME" }), /TRETU_APP_SECRET is still a default/);
  assert.equal(p({ TRETU_PLATFORM_URL: "", TRETU_APP_SECRET: "" }), "", "the platform part is optional");
  // dev/CI: Nakama defaults allowed, no Tretu sign-in needed
  assert.deepEqual(buildArgs("start", { NAKAMA_ALLOW_DEFAULTS: "1" }, { here }).problems, []);
  assert.deepEqual(productionProblems({}, {}).length, 7);
});

test("redaction: no secret value in a logged command line", () => {
  const { args } = buildArgs("start", good, { here });
  const line = redact(args);
  for (const v of [SECRET, good.NAKAMA_HTTP_KEY, good.NAKAMA_SESSION_ENCRYPTION_KEY, good.NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY,
    good.NAKAMA_CONSOLE_PASSWORD, good.NAKAMA_CONSOLE_SIGNING_KEY, "db-pass-0123"]) {
    assert.ok(!line.includes(v), "leaked: " + v);
  }
  assert.match(line, /--runtime\.env TRETU_APP_SECRET=\*\*\*/);
  assert.match(line, /--console\.password \*\*\*/);
  assert.match(line, /--database\.address nakama:\*\*\*@127\.0\.0\.1:5432\/nakama/);
  assert.match(line, /--console\.username hm-ops/, "non-secret values stay readable");
  assert.match(line, /--runtime\.env TRETU_AUTH_ISSUER=https:\/\/auth\.tretu\.de/);
});

test("env file and YAML readers", () => {
  assert.deepEqual(parseEnvFile("# c\nA=1\n B = 'two' \nC=\"x=y\"\nbad line\n"), { A: "1", B: "two", C: "x=y" });
  assert.deepEqual(yamlRuntimeEnv('name: x\nruntime:\n  http_key: "k"\n  env:\n    - "A=1"\n    - B=2 # note\nconsole:\n  env:\n    - "C=3"\n'), ["A=1", "B=2"]);
});

test("CLI: `args` prints the redacted command line, start refuses in production without keys", () => {
  const run = (env, cmd) => spawnSync(process.execPath, [path.join(here, "run.mjs"), cmd], { encoding: "utf8",
    env: { PATH: process.env.PATH, NAKAMA_LOCAL_CONFIG: "/nonexistent/local.yml", NAKAMA_ENV_FILE: "/nonexistent/.env", ...env } });
  const a = run(good, "args");
  assert.equal(a.status, 0, a.stderr);
  assert.ok(!a.stdout.includes(SECRET) && a.stdout.includes("TRETU_APP_SECRET=***"), a.stdout);
  const r = run({ NAKAMA_BIN: "/bin/false" }, "start");
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refusing to start: .*NAKAMA_HTTP_KEY is missing.*TRETU_AUTH_ISSUER is missing/);
});
