// PM2 processes for Hollowmere on the Tretu Hetzner server (no Docker). See HOSTING.md.
//
//   pm2 start ecosystem.config.cjs            first time
//   pm2 reload ecosystem.config.cjs --update-env
//
// hollowmere-nakama  Nakama API + realtime on 127.0.0.1:7350, console 127.0.0.1:7351
//                    (server/nakama/run.mjs runs "nakama migrate up" before every start)
// hollowmere-mcp     MCP relay for AI helpers on 127.0.0.1:8787, also serves /api/health and the
//                    Tretu platform webhook /api/tretu/webhook
//
// Secrets: server/.env (chmod 600; this file reads it and hands them to the two processes).
const fs = require("node:fs");
const path = require("node:path");

const root = __dirname;

// Minimal KEY=VALUE reader (no dependency); a missing file means "use the defaults".
function readEnv(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!m) continue;
    out[m[1]] = m[2].replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

const env = { ...readEnv(path.join(root, "server/.env")), ...process.env };
// What hollowmere-nakama needs from server/.env (server/nakama/run.mjs).
const NAKAMA_KEYS = ["NAKAMA_HTTP_KEY", "NAKAMA_SESSION_ENCRYPTION_KEY", "NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY",
  "NAKAMA_CONSOLE_USERNAME", "NAKAMA_CONSOLE_PASSWORD", "NAKAMA_CONSOLE_SIGNING_KEY", "NAKAMA_DATABASE_ADDRESS",
  "NAKAMA_LOCAL_CONFIG", "NAKAMA_DATA_DIR", "TRETU_AUTH_ISSUER", "TRETU_PLATFORM_URL", "TRETU_APP_ID", "TRETU_APP_SECRET",
  "HOLLOWMERE_PUBLIC_URL", "TRETU_PLATFORM_BACKOFF_SEC"];
const pick = (from, keys) => Object.fromEntries(keys.filter((k) => from[k] !== undefined && from[k] !== "").map((k) => [k, from[k]]));

module.exports = {
  apps: [
    {
      // server/nakama/run.mjs: Nakama's keys and the Tretu runtime env come from server/.env and go to
      // Nakama as flags (never written to a file, redacted in the log); it refuses to start while a
      // key is missing or still a default. Only these keys are passed on, nothing else from .env.
      name: "hollowmere-nakama",
      cwd: root,
      script: path.join(root, "server/nakama/run.mjs"),
      args: "start",
      interpreter: "node",
      env: {
        NODE_ENV: "production",
        NAKAMA_BIN: env.NAKAMA_BIN || "/opt/nakama/nakama",
        ...pick(env, NAKAMA_KEYS),
      },
      autorestart: true,
      restart_delay: 3000,
      max_restarts: 20,
      kill_timeout: 15000,
      time: true,
    },
    {
      name: "hollowmere-mcp",
      cwd: path.join(root, "server/mcp"),
      script: "server.mjs",
      interpreter: "node",
      env: {
        NODE_ENV: "production",
        MCP_HOST: "127.0.0.1",
        MCP_PORT: env.MCP_PORT || "8787",
        MCP_PUBLIC_URL: env.MCP_PUBLIC_URL || "https://mcp.hollowmere.tretu.de",
        NAKAMA_URL: "http://127.0.0.1:7350",
        NAKAMA_HTTP_KEY: env.NAKAMA_HTTP_KEY || "",
        // Tretu platform webhook (/api/tretu/webhook): off while empty.
        TRETU_APP_SECRET: env.TRETU_APP_SECRET || "",
      },
      autorestart: true,
      restart_delay: 3000,
      max_memory_restart: "256M",
      time: true,
    },
  ],
};
