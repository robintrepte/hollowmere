#!/usr/bin/env node
/**
 * Hollowmere MCP relay. Streamable HTTP JSON-RPC for Claude / Cursor / any MCP client.
 * Auth: Bearer personal-access token from the in-game agent panel, or a short OAuth code flow.
 * The world is simulated in the player's open game client; this process only relays.
 */
import http from "node:http";
import crypto from "node:crypto";

const PORT = Number(process.env.MCP_PORT || 8787);
const NAKAMA = process.env.NAKAMA_URL || "http://nakama:7350";
const HTTP_KEY = process.env.NAKAMA_HTTP_KEY || "dev_http_key_change_me";
const PUBLIC_URL = process.env.MCP_PUBLIC_URL || `http://127.0.0.1:${PORT}`;
const RATE = Number(process.env.MCP_RATE_PER_MIN || 60);

const TOOLS = [
  { name: "get_status", description: "Where you are, time, season, weather, energy, gold.", inputSchema: { type: "object", properties: {} } },
  { name: "look_around", description: "Tiles, objects, NPCs and players nearby, plus an ASCII sketch.", inputSchema: { type: "object", properties: { radius: { type: "number" } } } },
  { name: "get_inventory", description: "Items in the backpack.", inputSchema: { type: "object", properties: {} } },
  { name: "get_party", description: "Wildlings in the party.", inputSchema: { type: "object", properties: {} } },
  { name: "get_farm_overview", description: "Farm jobs, ripe crops, chest size.", inputSchema: { type: "object", properties: {} } },
  { name: "get_quests", description: "Active quests and the current step.", inputSchema: { type: "object", properties: {} } },
  { name: "get_map", description: "Current map id and name.", inputSchema: { type: "object", properties: {} } },
  { name: "get_shop", description: "A shop's stock. Pass id, or omit to list shops.", inputSchema: { type: "object", properties: { id: { type: "string" } } } },
  { name: "get_battle_state", description: "Whether a battle is on and the moves you can pick.", inputSchema: { type: "object", properties: {} } },
  { name: "get_dialogue", description: "The line on screen, if a villager is talking.", inputSchema: { type: "object", properties: {} } },
  { name: "read_chat", description: "Recent chat on this farm.", inputSchema: { type: "object", properties: {} } },
  { name: "wait_for_events", description: "Wait until the next command finishes; poll get_status if nothing is happening.", inputSchema: { type: "object", properties: {} } },
  { name: "walk_to", description: "Walk to a tile. Optional map id warps first.", inputSchema: { type: "object", properties: { x: { type: "number" }, y: { type: "number" }, map: { type: "string" } }, required: ["x", "y"] } },
  { name: "interact", description: "Talk or use the tile in front of you.", inputSchema: { type: "object", properties: {} } },
  { name: "use_tool", description: "Use the selected tool on a tile.", inputSchema: { type: "object", properties: { x: { type: "number" }, y: { type: "number" } } } },
  { name: "plant", description: "Plant the selected seed on a tile.", inputSchema: { type: "object", properties: { x: { type: "number" }, y: { type: "number" } } } },
  { name: "water_area", description: "Water a square of tiles.", inputSchema: { type: "object", properties: { x: { type: "number" }, y: { type: "number" }, r: { type: "number" } } } },
  { name: "harvest_area", description: "Harvest ripe crops in a square.", inputSchema: { type: "object", properties: { x: { type: "number" }, y: { type: "number" }, r: { type: "number" } } } },
  { name: "ship", description: "Empty the shipping bin.", inputSchema: { type: "object", properties: {} } },
  { name: "buy", description: "Buy from a shop. Needs the economy scope.", inputSchema: { type: "object", properties: { shop: { type: "string" }, id: { type: "string" }, n: { type: "number" } }, required: ["shop", "id"] } },
  { name: "sell", description: "Sell an inventory uid. Valuable sales need the economy scope.", inputSchema: { type: "object", properties: { uid: { type: "string" }, n: { type: "number" } }, required: ["uid"] } },
  { name: "craft", description: "Craft a recipe.", inputSchema: { type: "object", properties: { id: { type: "string" }, n: { type: "number" } }, required: ["id"] } },
  { name: "set_job", description: "Assign a farm job to a Wildling.", inputSchema: { type: "object", properties: { uid: { type: "string" }, job: { type: "string" } }, required: ["uid"] } },
  { name: "move_creature", description: "Move a Wildling to party or den.", inputSchema: { type: "object", properties: { uid: { type: "string" }, where: { type: "string" } }, required: ["uid"] } },
  { name: "chat_say", description: "Speak in farm chat. Needs the chat scope.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
  { name: "emote", description: "Play an emote the player knows.", inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } },
  { name: "sleep", description: "Go to bed (skips the night).", inputSchema: { type: "object", properties: {} } },
  { name: "narrate", description: "Show a short thought on the player's screen.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
  { name: "farm_routine", description: "Harvest ripe crops and water dry ones on the current map.", inputSchema: { type: "object", properties: {} } },
  { name: "go_shopping", description: "Buy a list from a shop. Needs economy.", inputSchema: { type: "object", properties: { shop: { type: "string" }, list: { type: "array" } } } },
  { name: "deposit_all", description: "Ship whatever is in the bin.", inputSchema: { type: "object", properties: {} } },
  { name: "battle_move", description: "Pick a move by index.", inputSchema: { type: "object", properties: { i: { type: "number" } } } },
  { name: "battle_switch", description: "Switch to party index.", inputSchema: { type: "object", properties: { i: { type: "number" } } } },
  { name: "battle_flee", description: "Run from a wild battle.", inputSchema: { type: "object", properties: {} } },
  { name: "enchant", description: "Take an enchanting-table offer.", inputSchema: { type: "object", properties: { tool: { type: "string" }, offer: { type: "number" } } } },
  { name: "casino_bet", description: "Place a casino bet. Needs economy.", inputSchema: { type: "object", properties: { game: { type: "string" }, bet: { type: "object" } } } },
];

const PROMPTS = [
  { name: "farmer", description: "Play as a careful farmer.", arguments: [] },
  { name: "coop_partner", description: "Help the host as a kind farmhand.", arguments: [] },
  { name: "battle_grind", description: "Train Wildlings in tall grass.", arguments: [] },
  { name: "optimize_farm", description: "Raise yield and keep jobs assigned.", arguments: [] },
];

const oauthClients = new Map();
const oauthCodes = new Map();
const hits = new Map();

function rateOk(key) {
  const now = Date.now();
  const arr = (hits.get(key) || []).filter((t) => now - t < 60_000);
  if (arr.length >= RATE) {
    hits.set(key, arr);
    return false;
  }
  arr.push(now);
  hits.set(key, arr);
  return true;
}

async function nakamaRpc(id, body) {
  const url = `${NAKAMA}/v2/rpc/${encodeURIComponent(id)}?http_key=${encodeURIComponent(HTTP_KEY)}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(JSON.stringify(body)),
  });
  const text = await res.text();
  let json = {};
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  if (!res.ok) {
    const err = json.error || json.message || text || res.statusText;
    throw new Error(typeof err === "string" ? err : JSON.stringify(err));
  }
  if (typeof json.payload === "string") {
    try { return JSON.parse(json.payload); } catch { return { payload: json.payload }; }
  }
  return json.payload || json;
}

async function relay(token, tool, args, actor) {
  const start = await nakamaRpc("agent_relay", { token, tool, args, actor });
  const id = start.id;
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 400));
    const poll = await nakamaRpc("agent_poll", { token, id });
    if (!poll.pending) return poll;
  }
  return { ok: false, error: "the game did not answer in time; is the farm open and the tab visible?" };
}

function bearer(req) {
  const h = req.headers.authorization || "";
  const m = h.match(/^Bearer\s+(\S+)/i);
  return m ? m[1] : "";
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(body);
}

function html(res, code, body) {
  res.writeHead(code, { "Content-Type": "text/html; charset=utf-8" });
  res.end(body);
}

function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id, message) {
  return { jsonrpc: "2.0", id, error: { code: -32000, message } };
}

async function handleRpc(msg, token) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return rpcResult(id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {}, resources: {}, prompts: {} },
      serverInfo: { name: "hollowmere", version: "1.0.0" },
    });
  }
  if (method === "notifications/initialized" || method === "ping") {
    return rpcResult(id, {});
  }
  if (method === "tools/list") {
    return rpcResult(id, { tools: TOOLS });
  }
  if (method === "tools/call") {
    if (!token) return rpcError(id, "sign in with a Hollowmere MCP token");
    if (!rateOk(token)) return rpcError(id, "slow down (rate limit)");
    const name = params?.name;
    const args = params?.arguments || {};
    if (name === "delete_save" || name === "wipe") return rpcError(id, "refused: saves cannot be deleted");
    try {
      const out = await relay(token, name, args, args.actor || "");
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(out.result ?? out, null, 2) }] });
    } catch (e) {
      return rpcError(id, e.message);
    }
  }
  if (method === "resources/list") {
    return rpcResult(id, { resources: [
      { uri: "hollowmere://handbook", name: "Hollowmere handbook", mimeType: "text/markdown" },
    ] });
  }
  if (method === "resources/read") {
    const text = [
      "# Hollowmere",
      "A cozy farm life sim. Crops grow in real time. Wildlings work jobs.",
      "Gold is in-game only. Casino chips have no real value.",
      "Never delete a save. Valuable sales need the economy scope.",
      "Keep the game tab visible; background tabs pause the world.",
      "Tools: " + TOOLS.map((t) => t.name).join(", "),
    ].join("\n");
    return rpcResult(id, { contents: [{ uri: params?.uri, mimeType: "text/markdown", text }] });
  }
  if (method === "prompts/list") {
    return rpcResult(id, { prompts: PROMPTS });
  }
  if (method === "prompts/get") {
    const texts = {
      farmer: "You are playing Hollowmere as a careful farmer. Look around, tend crops, talk to villagers. Narrate briefly.",
      coop_partner: "You are a kind farmhand on someone else's farm. Help; don't sell their valuables. Chat when you do something big.",
      battle_grind: "Train the party in tall grass. Use type advantage. Flee if you would faint.",
      optimize_farm: "Keep every farm Wildling on a job, water dry fields, harvest ripe crops, ship produce.",
    };
    return rpcResult(id, { messages: [{ role: "user", content: { type: "text", text: texts[params?.name] || texts.farmer } }] });
  }
  return rpcError(id, "unknown method " + method);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    });
    return res.end();
  }
  const url = new URL(req.url, PUBLIC_URL);
  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return json(res, 200, { ok: true, service: "hollowmere-mcp" });
  }
  if (req.method === "POST" && url.pathname === "/register") {
    const id = "cli_" + crypto.randomBytes(8).toString("hex");
    oauthClients.set(id, { redirect: true });
    return json(res, 201, {
      client_id: id,
      client_secret: crypto.randomBytes(12).toString("hex"),
      token_endpoint_auth_method: "none",
    });
  }
  if (req.method === "GET" && url.pathname === "/authorize") {
    const redirect = url.searchParams.get("redirect_uri") || "";
    const state = url.searchParams.get("state") || "";
    return html(res, 200, `<!doctype html><meta charset="utf-8"><title>Hollowmere MCP</title>
      <body style="font-family:sans-serif;max-width:28rem;margin:3rem auto">
      <h1>Connect Hollowmere</h1>
      <p>Paste a token from the in-game <b>AI agents</b> panel (Koop → Open agent panel).</p>
      <form method="POST" action="/authorize">
        <input type="hidden" name="redirect_uri" value="${redirect.replace(/"/g, "")}">
        <input type="hidden" name="state" value="${state.replace(/"/g, "")}">
        <input name="token" placeholder="hm_…" style="width:100%;padding:8px" required>
        <button>Connect</button>
      </form></body>`);
  }
  if (req.method === "POST" && url.pathname === "/authorize") {
    const raw = await readBody(req);
    const params = new URLSearchParams(raw);
    const token = params.get("token") || "";
    const redirect = params.get("redirect_uri") || "";
    const state = params.get("state") || "";
    const code = crypto.randomBytes(12).toString("hex");
    oauthCodes.set(code, token);
    if (redirect) {
      res.writeHead(302, { Location: `${redirect}${redirect.includes("?") ? "&" : "?"}code=${code}&state=${encodeURIComponent(state)}` });
      return res.end();
    }
    return json(res, 200, { code });
  }
  if (req.method === "POST" && url.pathname === "/token") {
    const raw = await readBody(req);
    const params = Object.fromEntries(new URLSearchParams(raw));
    const token = oauthCodes.get(params.code);
    if (!token) return json(res, 400, { error: "invalid_grant" });
    oauthCodes.delete(params.code);
    return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: 30 * 86400 });
  }
  if (url.pathname === "/mcp" || url.pathname === "/sse") {
    if (req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*" });
      res.write("event: endpoint\ndata: /mcp\n\n");
      return;
    }
    const raw = await readBody(req);
    let msg;
    try { msg = JSON.parse(raw); } catch { return json(res, 400, { error: "bad json" }); }
    const token = bearer(req);
    const out = await handleRpc(msg, token);
    return json(res, 200, out);
  }
  json(res, 404, { error: "not found" });
});

if (process.argv.includes("--self-test")) {
  const init = await handleRpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, "");
  if (!init.result?.serverInfo) {
    console.error("initialize failed");
    process.exit(1);
  }
  const tools = await handleRpc({ jsonrpc: "2.0", id: 2, method: "tools/list" }, "");
  if (!tools.result?.tools?.length) {
    console.error("tools/list failed");
    process.exit(1);
  }
  console.log("mcp self-test ok", tools.result.tools.length, "tools");
  process.exit(0);
}

server.listen(PORT, "0.0.0.0", () => {
  console.log(`hollowmere-mcp on :${PORT} → ${NAKAMA}`);
});
