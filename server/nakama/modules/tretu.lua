-- Tretu ecosystem integration for the Hollowmere Nakama server (library, used by hollowmere.lua).
--
-- Everything here is OFF unless the runtime env (server/nakama/local.yml -> runtime.env) sets it:
--   TRETU_AUTH_ISSUER   e.g. https://auth.tretu.de    -> "Mit Tretu-Konto anmelden" works
--   TRETU_PLATFORM_URL  e.g. https://tretu.de         -> events + presence are sent
--   TRETU_APP_ID        hollowmere                    (signing, contract section 3)
--   TRETU_APP_SECRET    32+ random bytes              (signing, never logged)
--   HOLLOWMERE_PUBLIC_URL  default https://hollowmere.tretu.de (presence joinUrl for co-op codes)
--
-- Sign-in: the game sends the Tretu access token in AuthenticateCustom vars.tretu_token. We ask the
-- issuer's userinfo endpoint (found through discovery, cached) who that is, and log the player into
-- the Nakama account with custom id "tretu:<sub>". The token never ends up in the Nakama session.
--
-- Discord carry-over: a player who used "Discord" before has an account with custom id
-- "discord:<id>". When a Tretu login brings a discord_id claim and no "tretu:<sub>" account exists
-- yet, that Discord account is re-keyed to "tretu:<sub>" with one atomic, guarded UPDATE, so the
-- same Nakama user id (and with it every cloud save, profile, agent token) simply continues under
-- the Tretu login. A marker in storage (tretu_links/discord:<id>) keeps the old Discord button
-- working: it now signs into the same, re-keyed account. Both steps are idempotent; see
-- carry_over_discord() for the crash-safety argument.
--
-- Events (contract section 4) are queued per player in storage (collection tretu_outbox) and sent
-- in batches, signed (contract section 3), from RPCs the game calls in the background (heartbeat,
-- battle report). A cloud save only queues, so saving never waits on the platform.

local M = {}

local nk = nil

local SYSTEM = "00000000-0000-0000-0000-000000000000"
local EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
local HTTP_TIMEOUT_MS = 5000          -- contract: never block longer than 5 s
local DISCOVERY_TTL_SEC = 3600
local SUB_CACHE_TTL_SEC = 300
local OUTBOX_MAX = 200                -- events kept per player while the platform is down
local OUTBOX_MAX_AGE_SEC = 86400      -- dropped after a day
local BATCH_MAX = 100                 -- contract: max 100 events per request
local HEARTBEAT_MIN_SEC = 30          -- presence expires after 120 s, the game beats every 60 s
local BATTLE_MIN_GAP_SEC = 8
local BATTLE_DAILY_MAX = 200
local MAX_DAYS_PER_SAVE = 14          -- client saves are client-authored; clamp what one save can claim
local MAX_BEFRIENDED_PER_SAVE = 40

M.EMPTY_SHA256 = EMPTY_SHA256
M.SYSTEM = SYSTEM

function M.init(nakama)
  nk = nakama
end

-- --- Config ------------------------------------------------------------------------------------

local function env(ctx, key)
  local v = ctx and ctx.env and ctx.env[key]
  if v == nil or v == "" then return nil end
  return v
end

local function strip_slash(s)
  return (string.gsub(s, "/+$", ""))
end

function M.config(ctx)
  local issuer = env(ctx, "TRETU_AUTH_ISSUER")
  local platform = env(ctx, "TRETU_PLATFORM_URL")
  local cfg = {
    issuer = issuer and strip_slash(issuer) or nil,
    platform = platform and strip_slash(platform) or nil,
    app_id = env(ctx, "TRETU_APP_ID") or "hollowmere",
    secret = env(ctx, "TRETU_APP_SECRET"),
    public_url = strip_slash(env(ctx, "HOLLOWMERE_PUBLIC_URL") or "https://hollowmere.tretu.de"),
  }
  cfg.auth_enabled = cfg.issuer ~= nil
  cfg.events_enabled = cfg.platform ~= nil and cfg.secret ~= nil
  return cfg
end

-- --- Signing (contract section 3) ------------------------------------------------------------------

-- nk.sha256_hash already returns lowercase hex, but rejects "" (so GET/DELETE use the constant).
function M.sha256_hex(body)
  if body == nil or body == "" then return EMPTY_SHA256 end
  return string.lower(nk.sha256_hash(body))
end

function M.signing_base(ts, method, path, body)
  return tostring(ts) .. "\n" .. string.upper(method) .. "\n" .. path .. "\n" .. M.sha256_hex(body)
end

-- nk.hmac_sha256_hash returns the raw 32-byte MAC; base16_encode turns it into hex.
function M.signature(secret, ts, method, path, body)
  local mac = nk.hmac_sha256_hash(M.signing_base(ts, method, path, body), secret)
  return "v1=" .. string.lower(nk.base16_encode(mac))
end

-- Path part of the platform URL ("https://tretu.de" -> "", "http://x:1/base" -> "/base").
function M.url_prefix(base)
  return strip_slash(string.match(base, "^https?://[^/]+(/.*)$") or "")
end

-- Contract test vector, checked once when the module loads (logged on mismatch).
M.TEST_VECTOR = {
  secret = "test-secret-123",
  ts = "1767225600",
  body = '{"id":"0b9f1c2e-1111-4a5b-8c9d-123456789abc","type":"stat.increment","app":"saga","sub":"user-sub-1","occurredAt":"2026-01-01T00:00:00.000Z","data":{"key":"saga.turns","by":1}}',
  body_sha = "4602011a4e61b23f5671fd07a722d0dbfa8ceefa4556218afc5d4aee7292062b",
  post_sig = "v1=f1a93767113e533347f3fc19e2ea26de609e2848ca366017516d7752c230243d",
  get_sig = "v1=2b0726b5f46af3137ecc0e51e27183533e357d620e2ab128fd7165610bc9ca6f",
}

function M.self_test()
  local v = M.TEST_VECTOR
  return M.sha256_hex(v.body) == v.body_sha
    and M.signature(v.secret, v.ts, "POST", "/api/v1/events", v.body) == v.post_sig
    and M.signature(v.secret, v.ts, "GET", "/api/v1/wallet/user-sub-1", "") == v.get_sig
end

-- --- Small helpers ---------------------------------------------------------------------------------

function M.now_sec()
  return math.floor(nk.time() / 1000)
end

function M.iso_time(ms)
  local secs = math.floor(ms / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", secs) .. string.format(".%03dZ", ms - secs * 1000)
end

local function http(method, url, headers, body)
  local ok, code, _, res = pcall(nk.http_request, url, method, headers, body or "", HTTP_TIMEOUT_MS)
  if not ok then
    return 0, nil, tostring(code)
  end
  return code, res, nil
end

local function decode(body)
  if type(body) ~= "string" or body == "" then return nil end
  local ok, v = pcall(nk.json_decode, body)
  if ok and type(v) == "table" then return v end
  return nil
end

-- A Tretu sub is a UUID; accept a conservative id alphabet so it is safe in a custom id and a path.
function M.valid_sub(sub)
  return type(sub) == "string" and #sub >= 1 and #sub <= 100 and string.match(sub, "^[%w%-_.]+$") ~= nil
end

-- preferred_username -> a Hollowmere name: letters, digits, _ ; 3..20 characters.
function M.clean_username(name)
  local s = string.gsub(tostring(name or ""), "[^%w_]", "")
  s = string.sub(s, 1, 20)
  if #s < 3 then return nil end
  return s
end

-- --- Identity (contract section 2) -----------------------------------------------------------------

function M.discovery(cfg)
  local key = "tretu:discovery:" .. cfg.issuer
  local cached = nk.localcache_get(key)
  if cached ~= nil then return cached end
  local code, body, err = http("GET", cfg.issuer .. "/.well-known/openid-configuration", {Accept = "application/json"}, "")
  local doc = code == 200 and decode(body) or nil
  if doc == nil then
    nk.logger_warn(string.format("Tretu discovery failed (status %s %s)", tostring(code), tostring(err or "")))
    return nil
  end
  if strip_slash(tostring(doc.issuer or "")) ~= cfg.issuer or type(doc.userinfo_endpoint) ~= "string" then
    nk.logger_error("Tretu discovery document does not match TRETU_AUTH_ISSUER")
    return nil
  end
  local out = {issuer = cfg.issuer, userinfo_endpoint = doc.userinfo_endpoint}
  nk.localcache_put(key, out, DISCOVERY_TTL_SEC)
  return out
end

function M.userinfo(cfg, access_token)
  local disc = M.discovery(cfg)
  if disc == nil then return nil, "Tretu sign-in is not reachable right now." end
  local code, body = http("GET", disc.userinfo_endpoint, {
    Authorization = "Bearer " .. access_token, Accept = "application/json", ["User-Agent"] = "Hollowmere",
  }, "")
  if code ~= 200 then return nil, "Tretu sign-in failed." end
  local info = decode(body)
  if info == nil or not M.valid_sub(info.sub) then return nil, "Tretu sign-in failed." end
  return info, nil
end

local function user_by_custom_id(custom_id)
  local rows = nk.sql_query("SELECT id::text AS id FROM users WHERE custom_id = $1", {custom_id})
  return rows[1] and rows[1].id or nil
end

local function username_taken(name)
  local rows = nk.sql_query("SELECT 1 AS x FROM users WHERE username = $1", {name})
  return rows[1] ~= nil
end

-- A free username for a new account: the preferred name, else name + digits, else tretu_<random>.
function M.pick_username(preferred, sub)
  local base = M.clean_username(preferred) or ("tretu_" .. string.sub(string.gsub(sub, "[^%w]", ""), 1, 8))
  if not username_taken(base) then return base end
  local stem = string.sub(base, 1, 15)
  for _ = 1, 6 do
    local candidate = stem .. "_" .. tostring(math.random(1000, 9999))
    if not username_taken(candidate) then return candidate end
  end
  return "tretu_" .. string.sub(string.gsub(nk.uuid_v4(), "-", ""), 1, 12)
end

-- Re-keys the player's existing "discord:<id>" account to "tretu:<sub>" (see the header).
-- 1. The marker tretu_links/discord:<id> is written first. It is only read when no
--    "discord:<id>" account exists any more, so writing it early is harmless.
-- 2. One UPDATE renames the custom id, guarded so it runs only while the Discord account still
--    exists and no "tretu:<sub>" account exists. A single statement is atomic in Postgres.
-- Crash between 1 and 2: the next Tretu login repeats both (same values). Running twice: the
-- guard matches no row. Two logins at once: the UNIQUE(custom_id) constraint lets one win; the
-- loser's UPDATE affects 0 rows or fails, and the login then finds the re-keyed account.
function M.carry_over_discord(discord_id, custom_id)
  if type(discord_id) ~= "string" or not string.match(discord_id, "^%d+$") or #discord_id > 32 then
    return false
  end
  local old_id = "discord:" .. discord_id
  local user_id = user_by_custom_id(old_id)
  if user_id == nil then return false end
  nk.storage_write({{
    collection = "tretu_links", key = old_id, user_id = SYSTEM,
    value = {custom_id = custom_id, user_id = user_id, at = M.now_sec()},
    permission_read = 0, permission_write = 0,
  }})
  local ok, n = pcall(nk.sql_exec, [[
    UPDATE users SET custom_id = $1, update_time = now()
    WHERE custom_id = $2 AND NOT EXISTS (SELECT 1 FROM users WHERE custom_id = $1)
  ]], {custom_id, old_id})
  if not ok then
    nk.logger_warn("Tretu: Discord carry-over did not apply: " .. tostring(n))
    return false
  end
  if n == 1 then
    nk.logger_info(string.format("Tretu: carried Discord account %s over to %s", user_id, custom_id))
  end
  nk.localcache_delete("tretu:sub:" .. user_id)
  return n == 1
end

-- Discord login after a carry-over: "discord:<id>" is gone, so follow the marker.
function M.redirect_discord(discord_id)
  local old_id = "discord:" .. tostring(discord_id)
  if user_by_custom_id(old_id) ~= nil then return nil end
  local rows = nk.storage_read({{collection = "tretu_links", key = old_id, user_id = SYSTEM}})
  local link = rows[1] and rows[1].value
  if link == nil or type(link.custom_id) ~= "string" then return nil end
  if user_by_custom_id(link.custom_id) == nil then return nil end
  return link.custom_id
end

-- AuthenticateCustom with vars.tretu_token. Returns the (modified) payload or raises.
function M.authenticate(ctx, payload, account, token)
  local cfg = M.config(ctx)
  if not cfg.auth_enabled then
    error({"Tretu sign-in is not enabled on this server.", 9})
  end
  if type(token) ~= "string" or #token < 8 or #token > 8192 then
    error({"Sign in with your Tretu account first.", 3})
  end
  local info, err = M.userinfo(cfg, token)
  if info == nil then
    error({err, 16})
  end
  local custom_id = "tretu:" .. info.sub
  local existing = user_by_custom_id(custom_id)
  if existing == nil and info.discord_id ~= nil then
    if M.carry_over_discord(tostring(info.discord_id), custom_id) then
      existing = user_by_custom_id(custom_id)
    end
  end
  if existing == nil then
    payload.username = M.pick_username(info.preferred_username, info.sub)
  end
  account.id = custom_id
  -- Session vars are signed into the Nakama session: keep the sub, drop the access token.
  account.vars = {tretu_sub = info.sub}
  payload.account = account
  return payload
end

-- --- Who is this player on Tretu? -------------------------------------------------------------------

function M.sub_for(ctx, user_id)
  user_id = user_id or ctx.user_id
  if user_id == nil or user_id == "" then return nil end
  local v = ctx.vars and ctx.vars.tretu_sub
  if user_id == ctx.user_id and M.valid_sub(v) then return v end
  local key = "tretu:sub:" .. user_id
  local cached = nk.localcache_get(key)
  if cached ~= nil then
    return cached ~= "" and cached or nil
  end
  local rows = nk.sql_query("SELECT custom_id FROM users WHERE id = $1::uuid", {user_id})
  local cid = rows[1] and rows[1].custom_id
  local sub = ""
  if type(cid) == "string" and string.sub(cid, 1, 6) == "tretu:" then
    sub = string.sub(cid, 7)
  end
  nk.localcache_put(key, sub, SUB_CACHE_TTL_SEC)
  return sub ~= "" and sub or nil
end

-- --- Platform calls -----------------------------------------------------------------------------------

function M.platform_request(cfg, method, path, body)
  local full_path = M.url_prefix(cfg.platform) .. path
  local ts = tostring(M.now_sec())
  local headers = {
    ["Content-Type"] = "application/json",
    ["x-tretu-app"] = cfg.app_id,
    ["x-tretu-timestamp"] = ts,
    ["x-tretu-signature"] = M.signature(cfg.secret, ts, method, full_path, body or ""),
    ["User-Agent"] = "Hollowmere",
  }
  local base = string.match(cfg.platform, "^(https?://[^/]+)") or cfg.platform
  local code, res, err = http(method, base .. full_path, headers, body or "")
  if code < 200 or code >= 300 then
    nk.logger_warn(string.format("Tretu platform %s %s -> %s %s", method, path, tostring(code), tostring(err or "")))
  end
  return code, res
end

function M.envelope(cfg, sub, type_, data)
  return {
    id = nk.uuid_v4(), type = type_, app = cfg.app_id, sub = sub,
    occurredAt = M.iso_time(nk.time()), data = data,
  }
end

local function read_outbox(user_id)
  local rows = nk.storage_read({{collection = "tretu_outbox", key = "pending", user_id = user_id}})
  if rows[1] == nil then return {}, nil end
  return rows[1].value.events or {}, rows[1].version
end

-- Conditional write so a save hook and a heartbeat never drop each other's events
-- (version "*" = only if the object does not exist yet).
local function write_outbox(user_id, events, version)
  return pcall(nk.storage_write, {{
    collection = "tretu_outbox", key = "pending", user_id = user_id,
    value = {events = events}, permission_read = 0, permission_write = 0,
    version = version or "*",
  }})
end

local function delete_outbox(user_id, version)
  return pcall(nk.storage_delete, {{collection = "tretu_outbox", key = "pending", user_id = user_id, version = version}})
end

function M.enqueue(user_id, new_events)
  if #new_events == 0 then return end
  for _ = 1, 3 do
    local events, version = read_outbox(user_id)
    for _, e in ipairs(new_events) do events[#events + 1] = {at = M.now_sec(), e = e} end
    while #events > OUTBOX_MAX do table.remove(events, 1) end
    if write_outbox(user_id, events, version) then return end
  end
  nk.logger_warn("Tretu: could not queue events for " .. user_id)
end

-- Sends queued events (one batch). Returns true when nothing is left to send.
function M.flush(cfg, user_id)
  if not cfg.events_enabled then return true end
  local events, version = read_outbox(user_id)
  if #events == 0 then return true end
  local now = M.now_sec()
  local fresh, batch, keep = {}, {}, {}
  for _, item in ipairs(events) do
    if now - (item.at or now) <= OUTBOX_MAX_AGE_SEC then
      fresh[#fresh + 1] = item
      if #batch < BATCH_MAX then batch[#batch + 1] = item.e else keep[#keep + 1] = item end
    end
  end
  if #batch > 0 then
    local code = M.platform_request(cfg, "POST", "/api/v1/events", nk.json_encode({events = batch}))
    if code < 200 or code >= 300 then
      -- Keep them for the next beat; the event ids make the retry idempotent on the platform.
      if #fresh ~= #events then write_outbox(user_id, fresh, version) end
      return false
    end
  end
  if #keep == 0 then
    delete_outbox(user_id, version)
  else
    write_outbox(user_id, keep, version)
  end
  return #keep == 0
end

-- --- Progress from cloud saves -----------------------------------------------------------------------

-- marks: {[slot] = {farm, day, befriended}}; meta: the save's meta block.
-- Returns days, befriended to report and the new mark. The first sight of a slot, a different
-- farm in the slot, or a step backwards only sets the baseline (no retroactive credit).
function M.progress_delta(mark, meta)
  local day = math.floor(tonumber(meta.day) or 0)
  local bef = math.floor(tonumber(meta.befriended or meta.dex) or 0)
  local farm = tostring(meta.farm or "")
  local new_mark = {farm = farm, day = day, befriended = bef}
  if mark == nil or mark.farm ~= farm or day < (mark.day or 0) then
    return 0, 0, new_mark
  end
  local days = math.max(0, math.min(day - (mark.day or 0), MAX_DAYS_PER_SAVE))
  local befriended = math.max(0, math.min(bef - (mark.befriended or 0), MAX_BEFRIENDED_PER_SAVE))
  if bef < (mark.befriended or 0) then new_mark.befriended = bef end
  return days, befriended, new_mark
end

-- After-hook for WriteStorageObjects: queue stat.increment events for new in-game days and
-- newly befriended Wildlings. Never raises (a save must not fail because of Tretu).
function M.after_saves(ctx, objects)
  local cfg = M.config(ctx)
  if not cfg.events_enabled or ctx.user_id == nil then return end
  local sub = M.sub_for(ctx)
  if sub == nil then return end
  local rows = nk.storage_read({{collection = "tretu_progress", key = "marks", user_id = ctx.user_id}})
  local marks = (rows[1] and rows[1].value.slots) or {}
  local days, befriended, changed = 0, 0, false
  for _, obj in ipairs(objects) do
    if obj.collection == "saves" then
      local save = decode(obj.value)
      local meta = save and save.meta
      if type(meta) == "table" then
        local d, b, mark = M.progress_delta(marks[obj.key], meta)
        days, befriended = days + d, befriended + b
        marks[obj.key] = mark
        changed = true
      end
    end
  end
  if not changed then return end
  nk.storage_write({{
    collection = "tretu_progress", key = "marks", user_id = ctx.user_id,
    value = {slots = marks}, permission_read = 0, permission_write = 0,
  }})
  local events = {}
  if days > 0 then
    events[#events + 1] = M.envelope(cfg, sub, "stat.increment", {key = "hollowmere.days.played", by = days})
  end
  if befriended > 0 then
    events[#events + 1] = M.envelope(cfg, sub, "stat.increment", {key = "hollowmere.creatures.befriended", by = befriended})
  end
  M.enqueue(ctx.user_id, events)
end

-- --- RPCs ---------------------------------------------------------------------------------------------

local function decode_payload(payload)
  return decode(payload) or {}
end

-- Throttle per player and node (localcache), returns true if the call should go ahead.
local function throttle(key, gap)
  local last = nk.localcache_get(key)
  local now = M.now_sec()
  if last ~= nil and now - last < gap then return false end
  nk.localcache_put(key, now, gap * 4)
  return true
end

-- The open game beats every 60 s while a Tretu player is signed in: presence + queued events.
-- payload: {"code": "ABC123"} while hosting co-op (checked against coop_codes) -> {"enabled": bool}
function M.rpc_heartbeat(ctx, payload)
  local cfg = M.config(ctx)
  local sub = cfg.events_enabled and M.sub_for(ctx) or nil
  if sub == nil then
    return nk.json_encode({enabled = false})
  end
  if not throttle("tretu:beat:" .. ctx.user_id, HEARTBEAT_MIN_SEC) then
    return nk.json_encode({enabled = true, throttled = true})
  end
  local req = decode_payload(payload)
  local presence = {status = "playing", activity = "Hollowmere"}
  local code = string.upper(tostring(req.code or "")):gsub("[^A-Z0-9]", "")
  if #code == 6 then
    local rows = nk.storage_read({{collection = "coop_codes", key = code, user_id = SYSTEM}})
    local row = rows[1] and rows[1].value
    if row and row.host == ctx.user_id and (row.expires or 0) > M.now_sec() then
      presence.joinUrl = cfg.public_url .. "/?join=" .. code
    end
  end
  M.platform_request(cfg, "PUT", "/api/v1/presence/" .. sub, nk.json_encode(presence))
  M.flush(cfg, ctx.user_id)
  return nk.json_encode({enabled = true})
end

-- Signing out: clear presence right away instead of letting it expire.
function M.rpc_offline(ctx, _payload)
  local cfg = M.config(ctx)
  local sub = cfg.events_enabled and M.sub_for(ctx) or nil
  if sub ~= nil then
    M.flush(cfg, ctx.user_id)
    M.platform_request(cfg, "DELETE", "/api/v1/presence/" .. sub, "")
  end
  return "{}"
end

local BATTLE_RESULTS = {win = "win", loss = "loss", lose = "loss", draw = "draw", befriend = "win"}

-- payload: {"result": "win"|"loss"|"draw", "kind": "wild"|"trainer"|"warden"|"rival"|"pvp", "duration": s}
function M.rpc_report_battle(ctx, payload)
  local cfg = M.config(ctx)
  local sub = cfg.events_enabled and M.sub_for(ctx) or nil
  if sub == nil then
    return nk.json_encode({enabled = false})
  end
  local req = decode_payload(payload)
  local result = BATTLE_RESULTS[tostring(req.result or "")]
  if result == nil then
    error({"result must be win, loss or draw", 3})
  end
  if not throttle("tretu:battle:" .. ctx.user_id, BATTLE_MIN_GAP_SEC) then
    return nk.json_encode({enabled = true, throttled = true})
  end
  local day_key = "tretu:battles:" .. ctx.user_id .. ":" .. tostring(math.floor(M.now_sec() / 86400))
  local count = (nk.localcache_get(day_key) or 0) + 1
  nk.localcache_put(day_key, count, 86400)
  if count > BATTLE_DAILY_MAX then
    return nk.json_encode({enabled = true, throttled = true})
  end
  local data = {game = "battle", result = result, mode = tostring(req.kind) == "pvp" and "multiplayer" or "bot"}
  local duration = math.floor(tonumber(req.duration) or 0)
  if duration > 0 and duration < 86400 then data.durationSec = duration end
  M.enqueue(ctx.user_id, {M.envelope(cfg, sub, "game.finished", data)})
  M.flush(cfg, ctx.user_id)
  return nk.json_encode({enabled = true})
end

return M
