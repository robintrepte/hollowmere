-- Tretu ecosystem integration for the Hollowmere Nakama server (library, used by hollowmere.lua).
--
-- Everything here is OFF unless the runtime env (server/nakama/local.yml -> runtime.env) sets it:
--   TRETU_AUTH_ISSUER   e.g. https://auth.tretu.de    -> "Mit Tretu-Konto anmelden" works
--   TRETU_PLATFORM_URL  e.g. https://tretu.de         -> events, presence, wallet + notifications
--   TRETU_APP_ID        hollowmere                    (signing, contract section 3)
--   TRETU_APP_SECRET    32+ random bytes              (signing, never logged, never sent to clients)
--   HOLLOWMERE_PUBLIC_URL  default https://hollowmere.tretu.de (presence joinUrl for co-op codes)
--   TRETU_PLATFORM_BACKOFF_SEC  default 15: after a platform outage (timeout / 5xx) every player
--                       skips the platform this long instead of waiting on it again
--
-- Sign-in: the game sends the Tretu access token in AuthenticateCustom vars.tretu_token. We ask the
-- issuer's userinfo endpoint (found through discovery, cached) who that is, and log the player into
-- the Nakama account with custom id "tretu:<sub>". The token never ends up in the Nakama session.
-- The discord_id / steam_id claims are kept server-side (storage tretu_identity/<sub>, SYSTEM-owned,
-- not readable by clients); steam_id is also recorded on the account metadata ("steam_id").
--
-- Carry-over: a player who used "Discord" before has an account with custom id "discord:<id>"; a
-- (future) native Steam account has users.steam_id = <SteamID64> or custom id "steam:<id>". When a
-- Tretu login brings a matching claim and no "tretu:<sub>" account exists yet, that account is
-- re-keyed to "tretu:<sub>" with one atomic, guarded UPDATE, so the same Nakama user id (and with
-- it every cloud save, profile, agent token) simply continues under the Tretu login. A marker in
-- storage (tretu_links/<provider>:<id>) keeps the old Discord button working: it now signs into
-- the same, re-keyed account. See carry_over() for the crash-safety argument.
--
-- Choose a farm: when BOTH a "tretu:<sub>" account and an old Discord/Steam account exist, nothing
-- is merged on its own. The game shows both farms (RPC tretu_farm_choice) and the player keeps one
-- (RPC tretu_farm_choose). The other account is archived in ONE database statement (a DO block:
-- custom id -> "archived:<user id>", disabled, an archive record in storage tretu_archive), never
-- deleted, and can be restored from the same menu for 90 days. RPC tretu_archive_purge (server
-- only, HTTP key) deletes archives older than that, if the operator runs it.
--
-- Events (contract section 4) are queued per player in storage (collection tretu_outbox) and sent
-- in batches, signed (contract section 3), from RPCs the game calls in the background (heartbeat,
-- battle report). A cloud save only queues, so saving never waits on the platform.
--
-- Wallet + notifications (RPC tretu_account): the Tretu-Credits balance and the unread count, read
-- from the platform server-side (signed, short timeout), cached per player for a minute and served
-- from the last good value (marked stale) while the platform is down.

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
local DISCOVERY_FAIL_TTL_SEC = 15     -- issuer down: don't ask again for every login attempt
local BACKOFF_DEFAULT_SEC = 15        -- platform down: skip it for this long (TRETU_PLATFORM_BACKOFF_SEC)
local SUMMARY_TTL_SEC = 60            -- wallet + unread count: reuse for a minute
local SUMMARY_FORCE_MIN_SEC = 15      -- "refresh now" at most this often per player
local SUMMARY_STALE_SEC = 1800        -- last good value shown (as stale) while the platform is down
local SUMMARY_HTTP_TIMEOUT_MS = 3000  -- two reads must stay well under the contract's 5 s
local ARCHIVE_KEEP_SEC = 90 * 86400   -- archived farms stay restorable for 90 days
local PROVIDERS = {"discord", "steam"}

M.EMPTY_SHA256 = EMPTY_SHA256
M.SYSTEM = SYSTEM
M.ARCHIVE_KEEP_SEC = ARCHIVE_KEEP_SEC

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
    backoff_sec = math.max(0, math.min(tonumber(env(ctx, "TRETU_PLATFORM_BACKOFF_SEC") or "") or BACKOFF_DEFAULT_SEC, 600)),
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

local function http(method, url, headers, body, timeout_ms)
  local ok, code, _, res = pcall(nk.http_request, url, method, headers, body or "", timeout_ms or HTTP_TIMEOUT_MS)
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

M.AUTH_DOWN = "Tretu sign-in is not reachable right now."
M.AUTH_FAILED = "Tretu sign-in failed."

function M.discovery(cfg)
  local key = "tretu:discovery:" .. cfg.issuer
  local cached = nk.localcache_get(key)
  if cached ~= nil then return cached end
  if nk.localcache_get(key .. ":down") ~= nil then return nil end
  local code, body, err = http("GET", cfg.issuer .. "/.well-known/openid-configuration", {Accept = "application/json"}, "")
  local doc = code == 200 and decode(body) or nil
  if doc == nil then
    nk.logger_warn(string.format("Tretu discovery failed (status %s %s)", tostring(code), tostring(err or "")))
    nk.localcache_put(key .. ":down", true, DISCOVERY_FAIL_TTL_SEC)
    return nil
  end
  if strip_slash(tostring(doc.issuer or "")) ~= cfg.issuer or type(doc.userinfo_endpoint) ~= "string" then
    nk.logger_error("Tretu discovery document does not match TRETU_AUTH_ISSUER")
    nk.localcache_put(key .. ":down", true, DISCOVERY_FAIL_TTL_SEC)
    return nil
  end
  local out = {issuer = cfg.issuer, userinfo_endpoint = doc.userinfo_endpoint}
  nk.localcache_put(key, out, DISCOVERY_TTL_SEC)
  return out
end

-- -> claims, nil | nil, message, grpc code (14 = issuer unreachable, 16 = token not accepted)
function M.userinfo(cfg, access_token)
  local disc = M.discovery(cfg)
  if disc == nil then return nil, M.AUTH_DOWN, 14 end
  local code, body = http("GET", disc.userinfo_endpoint, {
    Authorization = "Bearer " .. access_token, Accept = "application/json", ["User-Agent"] = "Hollowmere",
  }, "")
  if code == 0 or code >= 500 then
    nk.logger_warn("Tretu userinfo unreachable (status " .. tostring(code) .. ")")
    return nil, M.AUTH_DOWN, 14
  end
  if code ~= 200 then return nil, M.AUTH_FAILED, 16 end
  local info = decode(body)
  if info == nil or not M.valid_sub(info.sub) then return nil, M.AUTH_FAILED, 16 end
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

-- --- Linked identities (discord_id, steam_id claims) ------------------------------------------------

-- Discord snowflakes and SteamID64s are decimal strings. Numbers are refused: a JSON number this
-- large has already lost digits.
function M.valid_provider_id(provider, id)
  if type(id) ~= "string" or string.match(id, "^%d+$") == nil then return false end
  if provider == "discord" then return #id <= 32 end
  if provider == "steam" then return #id <= 20 end
  return false
end

-- Userinfo claims -> {discord = "<id>", steam = "<id>"} (each only when present and valid).
function M.claim_links(info)
  local out = {}
  if M.valid_provider_id("discord", info and info.discord_id) then out.discord = info.discord_id end
  if M.valid_provider_id("steam", info and info.steam_id) then out.steam = info.steam_id end
  return out
end

-- Server-only record of the player's linked ids, keyed by sub (survives a farm choice that moves
-- "tretu:<sub>" to another Nakama user). permission_read 0: clients never see it.
-- Tretu username (profile link https://tretu.de/u/<username>): printable, at most 64 characters.
function M.clean_tretu_username(name)
  if type(name) ~= "string" or #name < 1 or #name > 64 or string.match(name, "^[%w%-_.]+$") == nil then return nil end
  return name
end

function M.remember_identity(sub, links, username)
  local ok, err = pcall(nk.storage_write, {{
    collection = "tretu_identity", key = sub, user_id = SYSTEM,
    value = {discord = links.discord, steam = links.steam, username = M.clean_tretu_username(username), at = M.now_sec()},
    permission_read = 0, permission_write = 0,
  }})
  if not ok then nk.logger_warn("Tretu: could not store linked ids: " .. tostring(err)) end
end

function M.identity(sub)
  local rows = nk.storage_read({{collection = "tretu_identity", key = sub, user_id = SYSTEM}})
  local v = rows[1] and rows[1].value or {}
  local out = {}
  if M.valid_provider_id("discord", v.discord) then out.discord = v.discord end
  if M.valid_provider_id("steam", v.steam) then out.steam = v.steam end
  out.username = M.clean_tretu_username(v.username)
  return out
end

local ACCOUNT_COLUMNS = [[id::text AS id, custom_id, steam_id, username, display_name,
  floor(extract(epoch FROM update_time))::bigint AS updated,
  (disable_time > '1970-01-01 00:00:00+00') AS disabled]]

local function account_rows(where, params)
  return nk.sql_query("SELECT " .. ACCOUNT_COLUMNS .. " FROM users WHERE " .. where .. " ORDER BY create_time", params)
end

function M.account_by_custom_id(custom_id)
  return account_rows("custom_id = $1", {custom_id})[1]
end

-- Old accounts of this player from before the Tretu-Konto: "discord:<id>", and Steam accounts
-- (native users.steam_id, or custom id "steam:<id>"). Rows carry .kind = provider. Disabled
-- (banned) accounts are left alone.
function M.legacy_accounts(links, exclude_id)
  local out, seen = {}, {}
  local function add(rows, kind)
    for _, r in ipairs(rows) do
      if r.id ~= exclude_id and not seen[r.id] and not r.disabled then
        seen[r.id] = true
        r.kind = kind
        out[#out + 1] = r
      end
    end
  end
  if links.discord then add(account_rows("custom_id = $1", {"discord:" .. links.discord}), "discord") end
  if links.steam then add(account_rows("custom_id = $1 OR steam_id = $2", {"steam:" .. links.steam, links.steam}), "steam") end
  return out
end

-- The custom id a legacy account may be re-keyed from: only its own provider's id, or none (a
-- native Steam account). An account keyed to another Discord id is never re-keyed (its own Discord
-- button would stop finding it); the player chooses instead.
function M.rekeyable(row, provider, id)
  if row.custom_id == nil then return provider == "steam" end
  return row.custom_id == provider .. ":" .. id
end

-- Re-keys the player's only old <provider> account to "tretu:<sub>" (see the header).
-- 1. The marker tretu_links/<provider>:<id> is written first. It is only read when no
--    "<provider>:<id>" account exists any more, so writing it early is harmless.
-- 2. One UPDATE renames the custom id, guarded so it runs only while that account still has the
--    custom id we saw and no "tretu:<sub>" account exists. A single statement is atomic in Postgres.
-- Crash between 1 and 2: the next Tretu login repeats both (same values). Running twice: the
-- guard matches no row. Two logins at once: the UNIQUE(custom_id) constraint lets one win; the
-- loser's UPDATE affects 0 rows or fails, and the login then finds the re-keyed account.
function M.carry_over(provider, id, custom_id)
  if not M.valid_provider_id(provider, id) then return false end
  local rows = M.legacy_accounts({[provider] = id}, nil)
  if #rows ~= 1 or not M.rekeyable(rows[1], provider, id) then return false end
  local row = rows[1]
  M.write_marker(provider, id, custom_id)
  local guard = row.custom_id == nil and "custom_id IS NULL" or "custom_id = $3"
  local params = {custom_id, row.id}
  if row.custom_id ~= nil then params[3] = row.custom_id end
  local ok, n = pcall(nk.sql_exec, [[
    UPDATE users SET custom_id = $1, update_time = now()
    WHERE id = $2::uuid AND ]] .. guard .. [[ AND disable_time = '1970-01-01 00:00:00+00'
      AND NOT EXISTS (SELECT 1 FROM users WHERE custom_id = $1)
  ]], params)
  if not ok then
    nk.logger_warn("Tretu: " .. provider .. " carry-over did not apply: " .. tostring(n))
    return false
  end
  if n == 1 then
    nk.logger_info(string.format("Tretu: carried %s account %s over to a Tretu-Konto", provider, row.id))
  end
  nk.localcache_delete("tretu:sub:" .. row.id)
  return n == 1
end

function M.write_marker(provider, id, custom_id)
  nk.storage_write({{
    collection = "tretu_links", key = provider .. ":" .. id, user_id = SYSTEM,
    value = {custom_id = custom_id, at = M.now_sec()},
    permission_read = 0, permission_write = 0,
  }})
end

-- Discord login after a carry-over or a farm choice: "discord:<id>" is gone, so follow the marker.
function M.redirect_discord(discord_id)
  local old_id = "discord:" .. tostring(discord_id)
  if user_by_custom_id(old_id) ~= nil then return nil end
  local rows = nk.storage_read({{collection = "tretu_links", key = old_id, user_id = SYSTEM}})
  local link = rows[1] and rows[1].value
  if link == nil or type(link.custom_id) ~= "string" then return nil end
  if user_by_custom_id(link.custom_id) == nil then return nil end
  return link.custom_id
end

-- --- Switch tickets (a full, refreshable session after choosing another farm) -------------------------

local SWITCH_TTL_SEC = 120

local function ticket_key(ticket)
  return string.lower(nk.sha256_hash(ticket))
end

-- One-time ticket for the kept farm's user, redeemed by AuthenticateCustom vars.tretu_switch
-- within 2 minutes. Only its hash is stored.
function M.issue_switch_ticket(user_id, sub)
  local ticket = string.gsub(nk.uuid_v4() .. nk.uuid_v4(), "-", "")
  nk.storage_write({{
    collection = "tretu_switch", key = ticket_key(ticket), user_id = SYSTEM,
    value = {user_id = user_id, sub = sub, exp = M.now_sec() + SWITCH_TTL_SEC},
    permission_read = 0, permission_write = 0,
  }})
  return ticket
end

-- AuthenticateCustom with vars.tretu_switch: signs into the farm the ticket was issued for, as a
-- normal Nakama login (token + refresh token). Single use: the delete is conditional on the version.
function M.authenticate_switch(ctx, payload, account, ticket)
  if not M.config(ctx).auth_enabled then error({"Tretu sign-in is not enabled on this server.", 9}) end
  if type(ticket) ~= "string" or string.match(ticket, "^%x+$") == nil or #ticket ~= 64 then
    error({"Sign in with your Tretu account again.", 16})
  end
  local key = ticket_key(ticket)
  local rows = nk.storage_read({{collection = "tretu_switch", key = key, user_id = SYSTEM}})
  local row = rows[1]
  if row == nil then error({"Sign in with your Tretu account again.", 16}) end
  local used = pcall(nk.storage_delete, {{collection = "tretu_switch", key = key, user_id = SYSTEM, version = row.version}})
  local v = row.value or {}
  if not used or (v.exp or 0) < M.now_sec() or not M.valid_sub(v.sub) then
    error({"Sign in with your Tretu account again.", 16})
  end
  local acc = M.account_by_custom_id("tretu:" .. v.sub)
  if acc == nil or acc.id ~= v.user_id then error({"Sign in with your Tretu account again.", 16}) end
  account.id = "tretu:" .. v.sub
  account.vars = {tretu_sub = v.sub}
  payload.account = account
  return payload
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
  local info, err, code = M.userinfo(cfg, token)
  if info == nil then
    error({err, code or 16})
  end
  local custom_id = "tretu:" .. info.sub
  local links = M.claim_links(info)
  M.remember_identity(info.sub, links, info.preferred_username)
  local existing = user_by_custom_id(custom_id)
  if existing == nil then
    for _, provider in ipairs(PROVIDERS) do
      if links[provider] and M.carry_over(provider, links[provider], custom_id) then
        existing = user_by_custom_id(custom_id)
        break
      end
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

-- After a Tretu login: steam_id from the claims onto the account metadata (removed again when the
-- player unlinks Steam). One guarded UPDATE, so nothing is written when it did not change.
-- Account metadata from the identity record: "steam_id" (removed when unlinked) and
-- "tretu_username" (for the in-game profile link). One guarded UPDATE: nothing is written when
-- nothing changed. -> rows updated
function M.sync_metadata(sub, ident)
  local steam, uname = ident.steam or "", ident.username or ""
  return nk.sql_exec([[
    UPDATE users SET metadata = (metadata - 'steam_id' - 'tretu_username')
        || CASE WHEN $2::text = '' THEN '{}'::jsonb ELSE jsonb_build_object('steam_id', $2::text) END
        || CASE WHEN $3::text = '' THEN '{}'::jsonb ELSE jsonb_build_object('tretu_username', $3::text) END,
      update_time = now()
    WHERE custom_id = $1
      AND ((metadata->>'steam_id') IS DISTINCT FROM NULLIF($2::text, '')
        OR (metadata->>'tretu_username') IS DISTINCT FROM NULLIF($3::text, ''))
  ]], {"tretu:" .. sub, steam, uname})
end

function M.after_authenticate(ctx)
  local sub = ctx.vars and ctx.vars.tretu_sub
  if not M.valid_sub(sub) or ctx.user_id == nil or ctx.user_id == "" then return end
  M.sync_metadata(sub, M.identity(sub))
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

-- While this is set, platform calls are skipped (code 0) instead of each waiting for a timeout.
local BACKOFF_KEY = "tretu:platform:backoff"

function M.platform_backing_off()
  return nk.localcache_get(BACKOFF_KEY) ~= nil
end

-- Signed request to the platform. -> status (0 = not reachable or backing off), body
function M.platform_request(cfg, method, path, body, timeout_ms)
  if M.platform_backing_off() then return 0, nil end
  local full_path = M.url_prefix(cfg.platform) .. path
  local ts = tostring(M.now_sec())
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["x-tretu-app"] = cfg.app_id,
    ["x-tretu-timestamp"] = ts,
    ["x-tretu-signature"] = M.signature(cfg.secret, ts, method, full_path, body or ""),
    ["User-Agent"] = "Hollowmere",
  }
  local base = string.match(cfg.platform, "^(https?://[^/]+)") or cfg.platform
  local code, res, err = http(method, base .. full_path, headers, body or "", timeout_ms)
  if code < 200 or code >= 300 then
    -- Only method, our own path and the status: never headers (signature) or bodies.
    nk.logger_warn(string.format("Tretu platform %s %s -> %s %s", method, path, tostring(code), tostring(err or "")))
    if (code == 0 or code >= 500) and cfg.backoff_sec > 0 then
      nk.localcache_put(BACKOFF_KEY, true, cfg.backoff_sec)
    end
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

-- At most `max` calls per player and minute (per node), returns true if the call may go ahead.
function M.rate_ok(key, max)
  local window = math.floor(M.now_sec() / 60)
  local k = "tretu:rate:" .. key .. ":" .. tostring(window)
  local n = (nk.localcache_get(k) or 0) + 1
  nk.localcache_put(k, n, 120)
  return n <= max
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

-- --- Tretu-Credits + notifications for the in-game Tretu menu ---------------------------------------

-- Platform JSON -> integer >= 0 (balance may in theory be negative after an adjust), or nil.
function M.int_field(t, key, allow_negative)
  local v = type(t) == "table" and t[key] or nil
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge or math.floor(v) ~= v then return nil end
  if v < 0 and not allow_negative then return nil end
  return v
end

-- Reads balance and unread count from the platform. -> {balance, unread, at} or nil, status
function M.fetch_summary(cfg, sub)
  local code, body = M.platform_request(cfg, "GET", "/api/v1/wallet/" .. sub, "", SUMMARY_HTTP_TIMEOUT_MS)
  if code ~= 200 then return nil, code end
  local balance = M.int_field(decode(body), "balance", true)
  if balance == nil then return nil, 502 end
  local out = {balance = balance, at = M.now_sec()}
  code, body = M.platform_request(cfg, "GET", "/api/v1/users/" .. sub .. "/notifications/count", "", SUMMARY_HTTP_TIMEOUT_MS)
  if code == 200 then out.unread = M.int_field(decode(body), "unreadCount", false) end
  return out, 200
end

-- What the cache holds -> the RPC answer.
function M.summary_view(entry, state, now)
  local out = {enabled = true, platform = true, state = state}
  if entry ~= nil then
    out.balance = entry.balance
    out.currency = "TC"
    out.unread = entry.unread
    out.asOf = entry.at
    if state == "stale" then out.ageSec = math.max(0, now - (entry.at or now)) end
  end
  return out
end

-- RPC tretu_account. payload {"refresh": bool}
-- -> {enabled, platform, state: "ok"|"stale"|"unavailable", balance?, currency?, unread?, asOf?, ageSec?}
-- Never raises for platform trouble: the menu shows the last good value or a friendly note.
function M.rpc_account(ctx, payload)
  local cfg = M.config(ctx)
  local sub = cfg.auth_enabled and M.sub_for(ctx) or nil
  if sub == nil then
    return nk.json_encode({enabled = false})
  end
  if not cfg.events_enabled then
    return nk.json_encode({enabled = true, platform = false})
  end
  local req = decode_payload(payload)
  local key = "tretu:summary:" .. sub
  local cached = nk.localcache_get(key)
  local now = M.now_sec()
  local age = cached and (now - (cached.at or 0)) or math.huge
  local wants_fresh = req.refresh == true and age >= SUMMARY_FORCE_MIN_SEC
  if cached ~= nil and age < SUMMARY_TTL_SEC and not wants_fresh then
    return nk.json_encode(M.summary_view(cached, "ok", now))
  end
  if not M.rate_ok("account:" .. ctx.user_id, 20) then
    return nk.json_encode(M.summary_view(cached, cached and "stale" or "unavailable", now))
  end
  local entry, code = M.fetch_summary(cfg, sub)
  if entry ~= nil then
    if entry.unread == nil and cached ~= nil then entry.unread = cached.unread end
    nk.localcache_put(key, entry, SUMMARY_STALE_SEC)
    return nk.json_encode(M.summary_view(entry, "ok", now))
  end
  if code == 404 then
    -- The platform does not know this sub (yet): nothing to show, not an outage.
    return nk.json_encode({enabled = true, platform = true, state = "unavailable"})
  end
  return nk.json_encode(M.summary_view(cached, cached and "stale" or "unavailable", now))
end

-- --- Choose a farm when a Tretu account and an old Discord/Steam account both exist -----------------

local SAVE_SUMMARY_SQL = [[
  SELECT key, value->'meta'->>'farm' AS farm, value->'meta'->>'player' AS player,
         value->'meta'->>'day' AS day, value->'meta'->>'money' AS money,
         value->'meta'->>'befriended' AS befriended, value->'meta'->>'saved_at' AS saved_at
  FROM storage WHERE collection = 'saves' AND user_id = $1::uuid ORDER BY key LIMIT 6
]]

local function short(s, n)
  s = tostring(s or "")
  if #s > n then return string.sub(s, 1, n) end
  return s
end

local function num(v)
  local n = tonumber(v)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return 0 end
  return math.floor(n)
end

-- One cloud save row -> what the chooser shows.
function M.save_summary(row)
  return {
    slot = num(string.match(tostring(row.key or ""), "^slot_(%d)$")),
    farm = short(row.farm, 40), player = short(row.player, 40), day = num(row.day),
    money = num(row.money), befriended = num(row.befriended), savedAt = num(row.saved_at),
  }
end

function M.saves_of(user_id)
  local out = {}
  for _, row in ipairs(nk.sql_query(SAVE_SUMMARY_SQL, {user_id})) do
    out[#out + 1] = M.save_summary(row)
  end
  return out
end

local ARCHIVE_SQL = [[
  SELECT s.key AS id, u.username, u.display_name, s.value->>'kind' AS kind,
         s.value->>'custom_id' AS old_custom_id, s.value->>'steam_id' AS old_steam_id,
         (s.value->>'at')::bigint AS archived_at
  FROM storage s JOIN users u ON u.id::text = s.key
  WHERE s.collection = 'tretu_archive' AND s.user_id = '00000000-0000-0000-0000-000000000000'
    AND s.value->>'sub' = $1 AND u.custom_id = 'archived:' || u.id::text
    AND (s.value->>'at')::bigint >= $2
  ORDER BY archived_at DESC LIMIT 10
]]

-- Every account of this Tretu player: the active one, old ones still waiting for a choice, and
-- archived ones that can still be restored.
function M.farm_candidates(sub)
  local links = M.identity(sub)
  local current = M.account_by_custom_id("tretu:" .. sub)
  local legacy = M.legacy_accounts(links, current and current.id)
  local archived = nk.sql_query(ARCHIVE_SQL, {sub, M.now_sec() - ARCHIVE_KEEP_SEC})
  return {links = links, current = current, legacy = legacy, archived = archived}
end

local function option(row, kind, extra)
  local o = {id = row.id, kind = kind, name = short(row.display_name ~= nil and row.display_name ~= "" and row.display_name or row.username, 40),
    saves = M.saves_of(row.id)}
  if #o.saves == 0 then o.saves = nil end -- an empty Lua table would encode as {}
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- The session must belong to the active "tretu:<sub>" account (not an archived one).
local function tretu_session(ctx)
  local cfg = M.config(ctx)
  if not cfg.auth_enabled then return nil end
  local sub = ctx.vars and ctx.vars.tretu_sub
  if not M.valid_sub(sub) then return nil end
  return sub, cfg
end

-- RPC tretu_farm_choice -> {enabled, pending, keepDays, options:[{id, kind, current, name, saves?,
-- archivedAt?, restoreUntil?, was?}]}. kind: "tretu" | "discord" | "steam" | "archived".
function M.rpc_farm_choice(ctx, _payload)
  local sub = tretu_session(ctx)
  if sub == nil then return nk.json_encode({enabled = false}) end
  if not M.rate_ok("choice:" .. ctx.user_id, 12) then
    error({"Too many requests, try again in a minute.", 8})
  end
  local c = M.farm_candidates(sub)
  if c.current == nil or c.current.id ~= ctx.user_id then
    error({"Sign in with your Tretu account again.", 16})
  end
  local options = {option(c.current, "tretu", {current = true})}
  for _, r in ipairs(c.legacy) do options[#options + 1] = option(r, r.kind, {current = false}) end
  for _, r in ipairs(c.archived) do
    local at = num(r.archived_at)
    options[#options + 1] = option(r, "archived", {current = false, was = short(r.kind, 16),
      archivedAt = at, restoreUntil = at + ARCHIVE_KEEP_SEC})
  end
  return nk.json_encode({enabled = true, pending = #c.legacy > 0, keepDays = ARCHIVE_KEEP_SEC / 86400, options = options})
end

-- SQL literal from a value we generated or validated (uuids, subs, provider ids, custom ids).
-- Anything outside that alphabet raises, so nothing a client sends can reach the statement as SQL.
function M.sql_lit(v)
  local s = tostring(v)
  if string.match(s, "^[%w%-_.:]*$") == nil then error("unsafe SQL literal") end
  return "'" .. s .. "'"
end

local function lit_or_null(v)
  if v == nil or v == "" then return "NULL" end
  return M.sql_lit(v)
end

local function guard(column, v)
  if v == nil or v == "" then return column .. " IS NULL" end
  return column .. " = " .. M.sql_lit(v)
end

-- The whole choice as ONE statement (a DO block runs in one transaction): every other account is
-- archived (custom id freed, Steam id freed, disabled, archive record written), then the kept one
-- becomes "tretu:<sub>". Each UPDATE is guarded by the values the player was shown; if anything
-- changed in between, the block raises and nothing at all is applied.
-- plan = {sub, now, keep = row (with .kind, .old_steam_id for archived), archive = {rows}, steam = id?}
function M.choice_sql(plan)
  local L, sub = M.sql_lit, plan.sub
  local parts = {"DO $hm$\nBEGIN\n"}
  for _, row in ipairs(plan.archive) do
    parts[#parts + 1] = string.format([[
  UPDATE users SET custom_id = 'archived:' || id::text, steam_id = NULL, disable_time = now(), update_time = now()
    WHERE id = %s::uuid AND %s AND %s;
  IF NOT FOUND THEN RAISE EXCEPTION 'hollowmere_stale_choice'; END IF;
  INSERT INTO storage (collection, key, user_id, value, version, read, write)
    VALUES ('tretu_archive', %s, %s::uuid, jsonb_build_object('sub', %s::text, 'user_id', %s::text,
      'custom_id', %s::text, 'steam_id', %s::text, 'kind', %s::text, 'at', %d), md5(%s || ':' || %d::text), 0, 0)
    ON CONFLICT (collection, key, user_id) DO UPDATE SET value = EXCLUDED.value, version = EXCLUDED.version, update_time = now();
]], L(row.id), guard("custom_id", row.custom_id), guard("steam_id", row.steam_id),
      L(row.id), L(SYSTEM), L(sub), L(row.id), lit_or_null(row.custom_id), lit_or_null(row.steam_id), L(row.kind), plan.now,
      L(row.id), plan.now)
  end
  local keep = plan.keep
  local tretu_id = L("tretu:" .. sub)
  if keep.kind == "archived" then
    parts[#parts + 1] = string.format([[
  UPDATE users SET custom_id = %s, disable_time = '1970-01-01 00:00:00+00', update_time = now(),
      steam_id = CASE WHEN %s::text IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE steam_id = %s::text) THEN %s::text ELSE NULL END
    WHERE id = %s::uuid AND custom_id = 'archived:' || id::text;
  IF NOT FOUND THEN RAISE EXCEPTION 'hollowmere_stale_choice'; END IF;
  DELETE FROM storage WHERE collection = 'tretu_archive' AND key = %s AND user_id = %s::uuid;
]], tretu_id, lit_or_null(keep.old_steam_id), lit_or_null(keep.old_steam_id), lit_or_null(keep.old_steam_id),
      L(keep.id), L(keep.id), L(SYSTEM))
  elseif keep.kind ~= "tretu" then
    parts[#parts + 1] = string.format([[
  UPDATE users SET custom_id = %s, update_time = now()
    WHERE id = %s::uuid AND %s AND %s AND disable_time = '1970-01-01 00:00:00+00';
  IF NOT FOUND THEN RAISE EXCEPTION 'hollowmere_stale_choice'; END IF;
]], tretu_id, L(keep.id), guard("custom_id", keep.custom_id), guard("steam_id", keep.steam_id))
  else
    parts[#parts + 1] = string.format([[
  PERFORM 1 FROM users WHERE id = %s::uuid AND custom_id = %s;
  IF NOT FOUND THEN RAISE EXCEPTION 'hollowmere_stale_choice'; END IF;
]], L(keep.id), tretu_id)
  end
  if plan.steam ~= nil then
    -- The Steam id moves with the farm, so a native Steam login (if a Steam build ever uses one)
    -- finds the kept farm. Skipped when it is still taken.
    parts[#parts + 1] = string.format([[
  UPDATE users SET steam_id = %s WHERE id = %s::uuid AND steam_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM users WHERE steam_id = %s);
]], L(plan.steam), L(keep.id), L(plan.steam))
  end
  parts[#parts + 1] = "END\n$hm$"
  return table.concat(parts)
end

-- RPC tretu_farm_choose. payload {"keep": "<id from tretu_farm_choice>"}
-- -> {ok, changed, kept, archived: n, token?}. Idempotent: choosing the farm that is already
-- active with nothing left to decide is a no-op. When the kept farm is another Nakama user,
-- `token` is a session for it (the caller's session belonged to the farm that was archived).
function M.rpc_farm_choose(ctx, payload)
  local sub, cfg = tretu_session(ctx)
  if sub == nil then error({"Sign in with your Tretu account first.", 16}) end
  if not M.rate_ok("choose:" .. ctx.user_id, 5) then
    error({"Too many requests, try again in a minute.", 8})
  end
  local req = decode_payload(payload)
  local keep_id = tostring(req.keep or "")
  if string.match(keep_id, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") == nil then
    error({"Pick one of your farms.", 3})
  end
  local c = M.farm_candidates(sub)
  if c.current == nil or c.current.id ~= ctx.user_id then
    error({"Sign in with your Tretu account again.", 16})
  end
  c.current.kind = "tretu"
  local keep, archive = nil, {}
  for _, r in ipairs({c.current, unpack(c.legacy)}) do
    if r.id == keep_id then keep = r else archive[#archive + 1] = r end
  end
  if keep == nil then
    for _, r in ipairs(c.archived) do
      if r.id == keep_id then
        keep = {id = r.id, kind = "archived", username = r.username, old_steam_id = r.old_steam_id}
      end
    end
  end
  if keep == nil then error({"That farm is not one of yours.", 5}) end
  if keep.kind == "tretu" and #c.legacy == 0 then
    return nk.json_encode({ok = true, changed = false, kept = keep.id, archived = 0})
  end
  local plan = {sub = sub, now = M.now_sec(), keep = keep, archive = archive, steam = c.links.steam}
  -- The Discord (and Steam) button follows "tretu:<sub>" from now on, whichever farm that is.
  for provider, id in pairs(c.links) do M.write_marker(provider, id, "tretu:" .. sub) end
  if cfg.events_enabled then pcall(M.flush, cfg, ctx.user_id) end
  local ok, err = pcall(nk.sql_exec, M.choice_sql(plan))
  if not ok then
    if string.find(tostring(err), "hollowmere_stale_choice", 1, true) then
      error({"Your accounts changed in the meantime. Please look again.", 10})
    end
    nk.logger_error("Tretu farm choice failed: " .. tostring(err))
    error({"Could not switch farms right now. Nothing was changed.", 13})
  end
  local archived_ids = {}
  for _, r in ipairs(archive) do
    archived_ids[#archived_ids + 1] = r.id
    nk.localcache_delete("tretu:sub:" .. r.id)
  end
  nk.localcache_delete("tretu:sub:" .. keep.id)
  -- Sessions of archived accounts end now; a restored one may sign in again.
  if #archived_ids > 0 then pcall(nk.users_ban_id, archived_ids) end
  if keep.kind == "archived" then pcall(nk.users_unban_id, {keep.id}) end
  nk.logger_info(string.format("Tretu farm choice: kept %s (%s), archived %d account(s)", keep.id, keep.kind, #archived_ids))
  local out = {ok = true, changed = true, kept = keep.id, archived = #archived_ids}
  if keep.id ~= ctx.user_id then
    local username = keep.username
    if username == nil then
      local rows = nk.sql_query("SELECT username FROM users WHERE id = $1::uuid", {keep.id})
      username = rows[1] and rows[1].username or ""
    end
    -- `switch`: one-time ticket for a full session (AuthenticateCustom vars.tretu_switch, refreshable
    -- like any login). `token`: a plain session for the kept farm, used only if that login fails.
    out.switch = M.issue_switch_ticket(keep.id, sub)
    out.token = nk.authenticate_token_generate(keep.id, username, 0, {tretu_sub = sub})
  end
  return nk.json_encode(out)
end

-- --- Account events from the platform (webhook, relayed by hollowmere-mcp) ---------------------------

local function server_only(ctx)
  if ctx.user_id ~= nil and ctx.user_id ~= "" then
    error({"Not available.", 7})
  end
end

-- Nakama users that belong to this sub: the active "tretu:<sub>" account and its archived farms.
function M.accounts_of_sub(sub)
  local out = {}
  for _, r in ipairs(nk.sql_query([[
    SELECT id::text AS id FROM users WHERE custom_id = $1
    UNION
    SELECT u.id::text FROM storage s JOIN users u ON u.id::text = s.key
    WHERE s.collection = 'tretu_archive' AND s.user_id = '00000000-0000-0000-0000-000000000000'
      AND s.value->>'sub' = $2 AND u.custom_id = 'archived:' || u.id::text
  ]], {"tretu:" .. sub, sub})) do
    out[#out + 1] = r.id
  end
  return out
end

-- Everything Hollowmere keeps for a deleted Tretu-Konto, as ONE statement:
-- the "tretu:<sub>" account and the archived farms of that sub (their saves, profile, outbox,
-- progress marks go with them: storage rows cascade), their AI-helper tokens and inboxes, the co-op
-- codes they host, the identity record, archive records and the Discord/Steam markers.
function M.deletion_sql(sub)
  local L = M.sql_lit
  local S, T = L(sub), L("tretu:" .. sub)
  local sys = L(SYSTEM) .. "::uuid"
  local ids = string.format([[(SELECT id::text FROM users WHERE custom_id = %s
      UNION SELECT s.key FROM storage s JOIN users u ON u.id::text = s.key
      WHERE s.collection = 'tretu_archive' AND s.user_id = %s AND s.value->>'sub' = %s
        AND u.custom_id = 'archived:' || u.id::text)]], T, sys, S)
  return table.concat({
    "DO $hm$\nBEGIN\n",
    string.format("  CREATE TEMP TABLE hm_gone ON COMMIT DROP AS SELECT * FROM %s AS g(id);\n", ids),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'agent_tokens' AND value->>'user' IN (SELECT id FROM hm_gone);\n", sys),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'agent_inbox' AND key IN (SELECT id FROM hm_gone);\n", sys),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'coop_codes' AND value->>'host' IN (SELECT id FROM hm_gone);\n", sys),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_switch' AND value->>'sub' = %s;\n", sys, S),
    "  DELETE FROM users WHERE id::text IN (SELECT id FROM hm_gone);\n",
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_archive' AND value->>'sub' = %s;\n", sys, S),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_identity' AND key = %s;\n", sys, S),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_links' AND value->>'custom_id' = %s;\n", sys, T),
    "END\n$hm$",
  })
end

-- A legacy sub joined into another Tretu-Konto ({"mergedInto": target}). The "tretu:<sub>" farm
-- becomes "tretu:<target>" when the target has no Hollowmere account yet; otherwise it is archived
-- under the target, so the player can pick it in the farm choice. Archived farms of the old sub
-- move to the target too. Queued events of the old sub are dropped (the platform erased it).
function M.merge_sql(sub, target, now)
  local L = M.sql_lit
  local S, T, NT = L(sub), L("tretu:" .. sub), L("tretu:" .. target)
  local sys = L(SYSTEM) .. "::uuid"
  return table.concat({
    "DO $hm$\nBEGIN\n",
    string.format("  DELETE FROM storage WHERE collection = 'tretu_outbox' AND user_id IN (SELECT id FROM users WHERE custom_id = %s);\n", T),
    string.format("  IF EXISTS (SELECT 1 FROM users WHERE custom_id = %s) THEN\n", NT),
    string.format([[    INSERT INTO storage (collection, key, user_id, value, version, read, write)
      SELECT 'tretu_archive', id::text, %s, jsonb_build_object('sub', %s::text, 'user_id', id::text,
        'custom_id', custom_id, 'steam_id', steam_id, 'kind', 'tretu', 'at', %d, 'mergedFrom', %s::text),
        md5(id::text || ':merged:' || %d::text), 0, 0
      FROM users WHERE custom_id = %s
      ON CONFLICT (collection, key, user_id) DO UPDATE SET value = EXCLUDED.value, version = EXCLUDED.version, update_time = now();
    UPDATE users SET custom_id = 'archived:' || id::text, steam_id = NULL, disable_time = now(), update_time = now()
      WHERE custom_id = %s;
    DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_links' AND value->>'custom_id' = %s;
]], sys, L(target), now, S, now, T, T, sys, T),
    "  ELSE\n",
    string.format([[    UPDATE users SET custom_id = %s, update_time = now() WHERE custom_id = %s;
    UPDATE storage SET value = jsonb_set(value, '{custom_id}', to_jsonb(%s::text)), update_time = now()
      WHERE user_id = %s AND collection = 'tretu_links' AND value->>'custom_id' = %s;
]], NT, T, NT, sys, T),
    "  END IF;\n",
    string.format("  UPDATE storage SET value = jsonb_set(value, '{sub}', to_jsonb(%s::text)), update_time = now()\n    WHERE user_id = %s AND collection = 'tretu_archive' AND value->>'sub' = %s;\n", L(target), sys, S),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_identity' AND key = %s;\n", sys, S),
    string.format("  DELETE FROM storage WHERE user_id = %s AND collection = 'tretu_switch' AND value->>'sub' = %s;\n", sys, S),
    "END\n$hm$",
  })
end

-- Sessions of these users end now (their sub changed, or the account is gone / archived: `ban`
-- also closes their sockets and keeps old tokens out until they expire).
local function end_sessions(ids, ban)
  for _, id in ipairs(ids) do
    pcall(nk.session_logout, id)
    nk.localcache_delete("tretu:sub:" .. id)
  end
  if ban and #ids > 0 then pcall(nk.users_ban_id, ids) end
end

-- RPC tretu_user_deleted (server only, HTTP key; called by hollowmere-mcp for the platform's
-- user.deleted webhook). payload {"sub", "mergedInto"?} -> {deleted | merged, accounts}
-- Idempotent: a repeat finds nothing left and answers the same shape with accounts = 0.
function M.rpc_user_deleted(ctx, payload)
  server_only(ctx)
  local req = decode_payload(payload)
  local sub, target = req.sub, req.mergedInto
  if not M.valid_sub(sub) then error({"sub required", 3}) end
  if target ~= nil and (not M.valid_sub(target) or target == sub) then error({"bad mergedInto", 3}) end
  local ids = M.accounts_of_sub(sub)
  if target ~= nil then
    local active = M.account_by_custom_id("tretu:" .. sub)
    local into_existing = M.account_by_custom_id("tretu:" .. target) ~= nil
    nk.sql_exec(M.merge_sql(sub, target, M.now_sec()))
    -- Re-keyed: the farm now signs in with the surviving Tretu-Konto (old sessions carry the old sub).
    -- Archived: disabled like any farm the player did not keep.
    if active ~= nil then end_sessions({active.id}, into_existing) end
    nk.logger_info(string.format("Tretu: merged a deleted Tretu-Konto into another (%s)", into_existing and "archived" or "re-keyed"))
    return nk.json_encode({merged = true, archived = into_existing and active ~= nil, rekeyed = (not into_existing) and active ~= nil, accounts = active and 1 or 0})
  end
  nk.sql_exec(M.deletion_sql(sub))
  end_sessions(ids, true)
  nk.logger_info(string.format("Tretu: deleted %d account(s) of a deleted Tretu-Konto", #ids))
  return nk.json_encode({deleted = true, accounts = #ids})
end

-- RPC tretu_user_updated (server only). payload {"sub", "data": <auth user shape>}
-- Refreshes the linked ids and the account metadata (steam_id, tretu_username). Nothing is stored
-- for Tretu users who never played Hollowmere.
function M.rpc_user_updated(ctx, payload)
  server_only(ctx)
  local req = decode_payload(payload)
  local sub = req.sub
  if not M.valid_sub(sub) then error({"sub required", 3}) end
  local data = type(req.data) == "table" and req.data or {}
  local known = M.account_by_custom_id("tretu:" .. sub) ~= nil
  if not known then
    local rows = nk.storage_read({{collection = "tretu_identity", key = sub, user_id = SYSTEM}})
    known = rows[1] ~= nil
  end
  if not known then return nk.json_encode({updated = false}) end
  local links = type(data.links) == "table" and data.links or {}
  local ident = M.claim_links({discord_id = links.discord, steam_id = links.steam})
  local username = M.clean_tretu_username(data.username) or M.identity(sub).username
  M.remember_identity(sub, ident, username)
  ident.username = M.clean_tretu_username(username)
  local n = M.sync_metadata(sub, ident)
  return nk.json_encode({updated = true, metadata = n > 0})
end

-- RPC tretu_archive_purge (server to server only: needs the runtime HTTP key, refused for players).
-- Deletes archived farms older than 90 days. payload {"dryRun": bool} -> {deleted, kept}
function M.rpc_archive_purge(ctx, payload)
  if ctx.user_id ~= nil and ctx.user_id ~= "" then
    error({"Not available.", 7})
  end
  local req = decode_payload(payload)
  local rows = nk.sql_query([[
    SELECT s.key AS id, (u.custom_id = 'archived:' || u.id::text) AS archived
    FROM storage s LEFT JOIN users u ON u.id::text = s.key
    WHERE s.collection = 'tretu_archive' AND s.user_id = '00000000-0000-0000-0000-000000000000'
      AND (s.value->>'at')::bigint < $1
    ORDER BY s.key LIMIT 200
  ]], {M.now_sec() - ARCHIVE_KEEP_SEC})
  local deleted = 0
  for _, r in ipairs(rows) do
    if not req.dryRun then
      local ok = true
      if r.archived then ok = pcall(nk.account_delete_id, r.id, false) end
      if ok then
        nk.storage_delete({{collection = "tretu_archive", key = r.id, user_id = SYSTEM}})
        deleted = deleted + 1
      end
    end
  end
  if not req.dryRun then
    nk.sql_exec("DELETE FROM storage WHERE collection = 'tretu_switch' AND user_id = '00000000-0000-0000-0000-000000000000' AND (value->>'exp')::bigint < $1", {M.now_sec()})
  end
  nk.logger_info(string.format("Tretu archive purge: %d of %d archived farm(s) past 90 days removed", deleted, #rows))
  return nk.json_encode({deleted = deleted, due = #rows})
end

return M
