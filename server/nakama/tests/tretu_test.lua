-- Unit tests for server/nakama/modules/tretu.lua with a plain Lua 5.1 interpreter.
-- The real Nakama runtime is replaced by a fake `nk` whose hashes come from `openssl`
-- (same semantics as Nakama: sha256_hash -> hex, hmac_sha256_hash -> raw bytes).
--
--   lua5.1 server/nakama/tests/tretu_test.lua        (needs openssl on PATH)

local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/../modules/?.lua;" .. package.path

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function openssl(input, args)
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  f:write(input)
  f:close()
  local p = assert(io.popen("openssl dgst -sha256 -binary " .. args .. " < " .. sh_quote(tmp)))
  local out = p:read("*a")
  p:close()
  os.remove(tmp)
  assert(#out == 32, "openssl did not return a 32-byte digest")
  return out
end

local function hex(raw)
  return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local cache = {}
local fake_nk = {
  sha256_hash = function(s)
    assert(s ~= "", "Nakama's sha256_hash rejects empty input")
    return hex(openssl(s, ""))
  end,
  hmac_sha256_hash = function(s, key)
    assert(s ~= "" and key ~= "", "Nakama's hmac_sha256_hash rejects empty input")
    return openssl(s, "-hmac " .. sh_quote(key))
  end,
  base16_encode = function(s) return hex(s) end,
  time = function() return 1767225600123 end,
  uuid_v4 = function() return "00000000-0000-4000-8000-000000000001" end,
  localcache_get = function(k) return cache[k] end,
  localcache_put = function(k, v) cache[k] = v end,
  localcache_delete = function(k) cache[k] = nil end,
  logger_warn = function() end,
  logger_info = function() end,
  logger_error = function() end,
}

local tretu = require("tretu")
tretu.init(fake_nk)

local passed, failed = 0, 0
local function check(name, cond)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end
local function eq(name, got, want)
  check(name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")", got == want)
end

-- Contract section 3 test vectors.
local v = tretu.TEST_VECTOR
eq("sha256(body)", tretu.sha256_hex(v.body), "4602011a4e61b23f5671fd07a722d0dbfa8ceefa4556218afc5d4aee7292062b")
eq("sha256(empty)", tretu.sha256_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
eq("POST signature", tretu.signature("test-secret-123", "1767225600", "POST", "/api/v1/events", v.body),
  "v1=f1a93767113e533347f3fc19e2ea26de609e2848ca366017516d7752c230243d")
eq("GET signature", tretu.signature("test-secret-123", 1767225600, "get", "/api/v1/wallet/user-sub-1", ""),
  "v1=2b0726b5f46af3137ecc0e51e27183533e357d620e2ab128fd7165610bc9ca6f")
check("self_test", tretu.self_test())
eq("signing base", tretu.signing_base("1", "put", "/p?q=1", ""), "1\nPUT\n/p?q=1\n" .. tretu.EMPTY_SHA256)

-- Config: everything off without env.
local off = tretu.config({env = {}})
check("auth off without issuer", not off.auth_enabled)
check("events off without platform", not off.events_enabled)
local on = tretu.config({env = {
  TRETU_AUTH_ISSUER = "https://auth.tretu.de/", TRETU_PLATFORM_URL = "https://tretu.de",
  TRETU_APP_ID = "hollowmere", TRETU_APP_SECRET = "s",
}})
eq("issuer trailing slash stripped", on.issuer, "https://auth.tretu.de")
check("auth on", on.auth_enabled)
check("events on", on.events_enabled)
check("events need a secret", not tretu.config({env = {TRETU_PLATFORM_URL = "https://tretu.de"}}).events_enabled)
eq("default public url", on.public_url, "https://hollowmere.tretu.de")

-- Helpers.
eq("url prefix none", tretu.url_prefix("https://tretu.de"), "")
eq("url prefix path", tretu.url_prefix("http://127.0.0.1:3020/base/"), "/base")
eq("iso time", tretu.iso_time(1767225600123), "2026-01-01T00:00:00.123Z")
eq("clean username", tretu.clean_username("Röbin T.!"), "RbinT")
eq("clean username max 20", tretu.clean_username("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnopqrst")
eq("clean username too short", tretu.clean_username("a!"), nil)
check("valid sub uuid", tretu.valid_sub("7f0c3c2e-8d1b-4f5a-9b6e-2c1d0e9f8a7b"))
check("invalid sub slash", not tretu.valid_sub("a/b"))
check("invalid sub empty", not tretu.valid_sub(""))
check("invalid sub type", not tretu.valid_sub(42))

-- Progress deltas from save meta.
local d, b, mark = tretu.progress_delta(nil, {farm = "Moss", day = 40, befriended = 9})
check("first sight is a baseline", d == 0 and b == 0 and mark.day == 40 and mark.befriended == 9)
d, b, mark = tretu.progress_delta(mark, {farm = "Moss", day = 43, befriended = 11})
check("days and befriended counted", d == 3 and b == 2 and mark.day == 43)
d, b = tretu.progress_delta(mark, {farm = "Moss", day = 400, befriended = 500})
check("one save is clamped", d == 14 and b == 40)
d, b, mark = tretu.progress_delta({farm = "Moss", day = 43, befriended = 11}, {farm = "New", day = 1, befriended = 0})
check("new farm in the slot resets", d == 0 and b == 0 and mark.farm == "New" and mark.day == 1)
d, b = tretu.progress_delta({farm = "Moss", day = 10, befriended = 3}, {farm = "Moss", day = 10, dex = 5})
check("dex is the fallback for befriended", d == 0 and b == 2)

-- Envelope shape.
local e = tretu.envelope(on, "sub-1", "stat.increment", {key = "hollowmere.days.played", by = 1})
check("envelope", e.app == "hollowmere" and e.sub == "sub-1" and e.type == "stat.increment"
  and e.occurredAt == "2026-01-01T00:00:00.123Z" and e.id ~= nil)

print(string.format("TRETU LUA TESTS: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
