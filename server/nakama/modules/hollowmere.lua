-- Hollowmere server module: invite codes for co-op, cloud-save validation, health.
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
nk.register_req_before(before_write, "WriteStorageObjects")

nk.logger_info("Hollowmere module loaded")
