// PM2 processes for Hollowmere on the Tretu Hetzner server (no Docker). See HOSTING.md.
//
//   pm2 start ecosystem.config.cjs            first time
//   pm2 reload ecosystem.config.cjs --update-env
//
// hollowmere-nakama  Nakama API + realtime on 127.0.0.1:7350, console 127.0.0.1:7351
//                    (server/nakama/nakama.sh runs "nakama migrate up" before every start)
// hollowmere-mcp     MCP relay for AI helpers on 127.0.0.1:8787, also serves /api/health
//
// Secrets: server/.env (this file reads it) and server/nakama/local.yml (Nakama reads it).
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

module.exports = {
  apps: [
    {
      name: "hollowmere-nakama",
      cwd: root,
      script: path.join(root, "server/nakama/nakama.sh"),
      args: "start",
      interpreter: "bash",
      env: {
        NAKAMA_BIN: env.NAKAMA_BIN || "/opt/nakama/nakama",
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
      },
      autorestart: true,
      restart_delay: 3000,
      max_memory_restart: "256M",
      time: true,
    },
  ],
};
