-- Hollowmere server module: invite codes for co-op, cloud-save validation, error reports,
-- opt-in play stats, health.
local nk = require("nakama")

local SYSTEM = "00000000-0000-0000-0000-000000000000"
local CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no 0/O/1/I

local function getenv(ctx, key, default)
  local v = ctx.env and ctx.env[key]
  if v == nil or v == "" then return default end
  return v
end

local function new_code()
  local out = {}
  for i = 1, 6 do
    local n = math.random(1, #CODE_ALPHABET)
    out[i] = CODE_ALPHABET:sub(n, n)
  end
  return table.concat(out)
end

-- Host registers its relayed match and gets a short code friends can type.
-- payload: {"match_id": "..."}  ->  {"code": "ABC123"}
local function create_coop_code(ctx, payload)
  local req = nk.json_decode(payload or "{}")
  if type(req.match_id) ~= "string" or #req.match_id < 10 then
    error({"match_id required", 3})
  end
  local ttl = tonumber(getenv(ctx, "code_ttl_sec", "43200"))
  for _ = 1, 8 do
    local code = new_code()
    local existing = nk.storage_read({{collection = "coop_codes", key = code, user_id = SYSTEM}})
    local taken = existing[1] ~= nil and (existing[1].value.expires or 0) > nk.time() / 1000
    if not taken then
      nk.storage_write({{
        collection = "coop_codes", key = code, user_id = SYSTEM,
        value = {match_id = req.match_id, host = ctx.user_id, host_name = ctx.username, expires = nk.time() / 1000 + ttl},
        permission_read = 0, permission_write = 0,
      }})
      return nk.json_encode({code = code})
    end
  end
  error({"could not allocate a code, try again", 13})
end

-- payload: {"code": "ABC123"}  ->  {"match_id": "...", "host_name": "..."}
local function resolve_coop_code(ctx, payload)
  local req = nk.json_decode(payload or "{}")
  local code = string.upper(tostring(req.code or "")):gsub("[^A-Z0-9]", "")
  if #code ~= 6 then
    error({"codes are 6 letters", 3})
  end
  local rows = nk.storage_read({{collection = "coop_codes", key = code, user_id = SYSTEM}})
  local row = rows[1]
  if row == nil or (row.value.expires or 0) < nk.time() / 1000 then
    error({"that farm isn't open right now", 5})
  end
  return nk.json_encode({match_id = row.value.match_id, host_name = row.value.host_name})
end

local function close_coop_code(ctx, payload)
  local req = nk.json_decode(payload or "{}")
  local code = string.upper(tostring(req.code or ""))
  local rows = nk.storage_read({{collection = "coop_codes", key = code, user_id = SYSTEM}})
  if rows[1] ~= nil and rows[1].value.host == ctx.user_id then
    nk.storage_delete({{collection = "coop_codes", key = code, user_id = SYSTEM}})
  end
  return "{}"
end

local function clip(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n) end
  return s
end

-- Error reports, grouped by signature across all players (Nakama console: storage "errors").
-- payload: {"reports": [{"sig", "msg", "where", "kind", "count", "version", "platform", "log"}]}
local function report_errors(ctx, payload)
  local req = nk.json_decode(payload or "{}")
  for i, r in ipairs(req.reports or {}) do
    if i > 25 then break end
    local sig = clip(r.sig, 240)
    if sig ~= "" then
      local key = nk.md5_hash(sig)
      local rows = nk.storage_read({{collection = "errors", key = key, user_id = SYSTEM}})
      local v = rows[1] and rows[1].value or {
        sig = sig, msg = clip(r.msg, 600), where = clip(r.where, 300), kind = clip(r.kind, 16),
        first = nk.time() / 1000, count = 0, reporters = 0, versions = {},
      }
      v.count = (v.count or 0) + math.max(1, math.min(tonumber(r.count) or 1, 1000))
      v.reporters = (v.reporters or 0) + 1
      v.last = nk.time() / 1000
      v.versions = v.versions or {}
      v.versions[clip(r.version, 24)] = true
      v.platform = clip(r.platform, 24)
      if r.log and r.log ~= "" then v.log = clip(r.log, 6000) end
      nk.storage_write({{collection = "errors", key = key, user_id = SYSTEM, value = v, permission_read = 0, permission_write = 0}})
    end
  end
  return "{}"
end

-- Opt-in play stats: minutes played per UTC day, so retention (D1/D7/D30) can be read per player.
-- payload: {"minutes": n, "new_session": bool, "version", "platform", "game_day"}
local function track_session(ctx, payload)
  local req = nk.json_decode(payload or "{}")
  local minutes = math.max(0, math.min(tonumber(req.minutes) or 0, 60))
  local today = tostring(math.floor(nk.time() / 86400000))
  local rows = nk.storage_read({{collection = "analytics", key = "sessions", user_id = ctx.user_id}})
  local v = rows[1] and rows[1].value or {first_day = today, sessions = 0, minutes = 0, days = {}, active_days = 0}
  if req.new_session then v.sessions = v.sessions + 1 end
  v.minutes = v.minutes + minutes
  if v.days[today] == nil then
    v.active_days = (v.active_days or 0) + 1
    if v.active_days <= 400 then v.days[today] = 0 end
  end
  if v.days[today] ~= nil then v.days[today] = v.days[today] + minutes end
  v.last_day = today
  v.version = clip(req.version, 24)
  v.platform = clip(req.platform, 24)
  v.game_day = tonumber(req.game_day) or 0
  nk.storage_write({{collection = "analytics", key = "sessions", user_id = ctx.user_id, value = v, permission_read = 0, permission_write = 0}})
  return "{}"
end

local function health(_ctx, _payload)
  return nk.json_encode({ok = true, time = nk.time()})
end

-- Clients may only write their own save slots, with sane sizes and private permissions.
local function before_write(ctx, payload)
  local max_bytes = tonumber(getenv(ctx, "max_save_bytes", "3145728"))
  for _, obj in ipairs(payload.objects or {}) do
    if obj.collection ~= "saves" then
      error({"writes allowed only to saves", 7})
    end
    if not string.match(obj.key or "", "^slot_[0-5]$") then
      error({"bad save slot", 3})
    end
    if #(obj.value or "") > max_bytes then
      error({"save too large", 3})
    end
    local ok, decoded = pcall(nk.json_decode, obj.value)
    if not ok or type(decoded) ~= "table" or decoded.version == nil then
      error({"save must be a Hollowmere save", 3})
    end
    obj.permission_read = 1
    obj.permission_write = 1
  end
  return payload
end

nk.register_rpc(create_coop_code, "create_coop_code")
nk.register_rpc(resolve_coop_code, "resolve_coop_code")
nk.register_rpc(close_coop_code, "close_coop_code")
nk.register_rpc(health, "health")
nk.register_rpc(report_errors, "report_errors")
nk.register_rpc(track_session, "track_session")
nk.register_req_before(before_write, "WriteStorageObjects")

nk.logger_info("Hollowmere module loaded")
