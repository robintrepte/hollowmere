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
local clock_ms = 1767225600123
local http_log, http_answers = {}, {}
-- Minimal JSON for the platform bodies these tests use (flat objects of numbers / strings).
local function json_decode(s)
  local lua_src = s:gsub("%[", "{"):gsub("%]", "}"):gsub('"([%w_]+)"%s*:', '["%1"]='):gsub("null", "nil")
  local fn = assert(loadstring("return " .. lua_src))
  return fn()
end
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
  time = function() return clock_ms end,
  sql_query = function() return {} end,
  json_encode = function(t) return t end, -- tests inspect the table the RPC would encode
  json_decode = json_decode,
  http_request = function(url, method, headers, body, timeout)
    http_log[#http_log + 1] = {url = url, method = method, headers = headers, timeout = timeout}
    local a = table.remove(http_answers, 1) or {0}
    if a.raise then error("connection refused") end
    return a[1], {}, a[2] or ""
  end,
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

-- Linked ids from claims (Discord snowflakes, SteamID64) are decimal strings only.
check("discord id ok", tretu.valid_provider_id("discord", "123456789012345678"))
check("steam id ok", tretu.valid_provider_id("steam", "76561198000000001"))
check("steam id too long", not tretu.valid_provider_id("steam", "765611980000000012345"))
check("number claim refused (lost digits)", not tretu.valid_provider_id("steam", 76561198000000001))
check("non-digits refused", not tretu.valid_provider_id("discord", "12a"))
check("unknown provider refused", not tretu.valid_provider_id("minecraft", "1"))
local links = tretu.claim_links({discord_id = "42", steam_id = "76561198000000001", minecraft_uuid = "x"})
check("claim links", links.discord == "42" and links.steam == "76561198000000001")
links = tretu.claim_links({steam_id = 7656119})
check("numeric steam claim ignored", links.steam == nil and links.discord == nil)
check("native steam account (no custom id) is re-keyable", tretu.rekeyable({custom_id = nil}, "steam", "1"))
check("steam:<id> account is re-keyable", tretu.rekeyable({custom_id = "steam:1"}, "steam", "1"))
check("own discord account is re-keyable", tretu.rekeyable({custom_id = "discord:9"}, "discord", "9"))
check("an account keyed to another id is not re-keyed", not tretu.rekeyable({custom_id = "discord:8"}, "steam", "1"))
check("discord needs its custom id", not tretu.rekeyable({custom_id = nil}, "discord", "9"))

-- SQL literals: only generated / validated values, anything else raises.
eq("sql literal", tretu.sql_lit("tretu:7f0c3c2e-8d1b-4f5a-9b6e-2c1d0e9f8a7b"), "'tretu:7f0c3c2e-8d1b-4f5a-9b6e-2c1d0e9f8a7b'")
for _, bad in ipairs({"a'b", "a;b", "a b", "$hm$", "a\\b", "a\nb", "a--b'"}) do
  check("sql literal refuses " .. bad, not pcall(tretu.sql_lit, bad))
end

-- The farm switch statement: one DO block, every UPDATE guarded by what the player was shown.
local T = "11111111-1111-4111-8111-111111111111"
local D = "22222222-2222-4222-8222-222222222222"
local SUB = "7f0c3c2e-8d1b-4f5a-9b6e-2c1d0e9f8a7b"
local q = tretu.choice_sql({sub = SUB, now = 1767225600,
  keep = {id = D, kind = "discord", custom_id = "discord:555", steam_id = nil},
  archive = {{id = T, kind = "tretu", custom_id = "tretu:" .. SUB, steam_id = nil}}, steam = "76561198000000001"})
check("one DO block", q:match("^DO %$hm%$\nBEGIN\n") ~= nil and q:match("END\n%$hm%$$") ~= nil)
local a_at = q:find("custom_id = 'archived:' || id::text", 1, true)
local k_at = q:find("SET custom_id = 'tretu:" .. SUB .. "'", 1, true)
check("archives first, then re-keys the kept account", a_at ~= nil and k_at ~= nil and a_at < k_at)
check("archive guarded by the shown custom id", q:find("WHERE id = '" .. T .. "'::uuid AND custom_id = 'tretu:" .. SUB .. "' AND steam_id IS NULL", 1, true) ~= nil)
check("kept account guarded too", q:find("WHERE id = '" .. D .. "'::uuid AND custom_id = 'discord:555' AND steam_id IS NULL", 1, true) ~= nil)
check("stale state aborts everything", select(2, q:gsub("RAISE EXCEPTION 'hollowmere_stale_choice'", "")) == 2)
check("archive record in the same statement", q:find("INSERT INTO storage", 1, true) ~= nil and q:find("'tretu_archive'", 1, true) ~= nil)
check("steam id follows the farm", q:find("UPDATE users SET steam_id = '76561198000000001' WHERE id = '" .. D .. "'::uuid AND steam_id IS NULL", 1, true) ~= nil)
check("bad values never reach the statement", not pcall(tretu.choice_sql, {sub = "x'y", now = 1, keep = {id = D, kind = "tretu"}, archive = {}}))
local r = tretu.choice_sql({sub = SUB, now = 1, keep = {id = T, kind = "archived", old_steam_id = nil}, archive = {}})
check("restore re-enables and drops the archive record", r:find("disable_time = '1970-01-01 00:00:00+00'", 1, true) ~= nil
  and r:find("DELETE FROM storage WHERE collection = 'tretu_archive'", 1, true) ~= nil)
r = tretu.choice_sql({sub = SUB, now = 1, keep = {id = T, kind = "tretu"}, archive = {{id = D, kind = "discord", custom_id = "discord:555", steam_id = "765"}}})
check("keeping the active account only checks it is still active", r:find("PERFORM 1 FROM users WHERE id = '" .. T .. "'::uuid AND custom_id = 'tretu:" .. SUB .. "'", 1, true) ~= nil
  and r:find("steam_id = '765'", 1, true) ~= nil)

-- Save summaries from storage rows (text columns).
local sv = tretu.save_summary({key = "slot_3", farm = string.rep("F", 60), player = "Mia", day = "41", money = "1200.0", befriended = nil, saved_at = "1767225600.5"})
check("save summary", sv.slot == 3 and #sv.farm == 40 and sv.player == "Mia" and sv.day == 41 and sv.money == 1200 and sv.befriended == 0 and sv.savedAt == 1767225600)

-- Platform numbers.
eq("int field", tretu.int_field({balance = 120}, "balance"), 120)
eq("negative balance allowed when asked", tretu.int_field({balance = -5}, "balance", true), -5)
eq("negative count refused", tretu.int_field({unreadCount = -1}, "unreadCount"), nil)
eq("fraction refused", tretu.int_field({balance = 1.5}, "balance"), nil)
eq("string refused", tretu.int_field({balance = "9"}, "balance"), nil)
eq("missing", tretu.int_field(nil, "balance"), nil)

-- Rate limit per minute window.
cache = {}
local allowed = 0
for _ = 1, 7 do if tretu.rate_ok("t", 5) then allowed = allowed + 1 end end
eq("rate limit", allowed, 5)
clock_ms = clock_ms + 60000
check("next minute is allowed again", tretu.rate_ok("t", 5))

-- tretu_account: cache, forced refresh, outage -> stale -> backoff -> recovery.
cache = {}
local ctx = {user_id = "u1", vars = {tretu_sub = SUB}, env = {
  TRETU_AUTH_ISSUER = "https://auth.tretu.de", TRETU_PLATFORM_URL = "https://tretu.de",
  TRETU_APP_ID = "hollowmere", TRETU_APP_SECRET = "test-secret-123", TRETU_PLATFORM_BACKOFF_SEC = "20",
}}
check("off without a Tretu session", tretu.rpc_account({user_id = "g", env = ctx.env}, "{}").enabled == false)
check("platform part off without a secret", tretu.rpc_account({user_id = "u1", vars = ctx.vars, env = {TRETU_AUTH_ISSUER = "https://auth.tretu.de"}}, "{}").platform == false)
http_log, http_answers = {}, {{200, '{"sub":"x","balance":120,"currency":"TC"}'}, {200, '{"unreadCount":3}'}}
local res = tretu.rpc_account(ctx, "{}")
check("summary ok", res.state == "ok" and res.balance == 120 and res.unread == 3 and res.currency == "TC")
check("two signed GETs with a short timeout", #http_log == 2 and http_log[1].url == "https://tretu.de/api/v1/wallet/" .. SUB
  and http_log[2].url == "https://tretu.de/api/v1/users/" .. SUB .. "/notifications/count"
  and http_log[1].method == "GET" and http_log[1].timeout == 3000
  and http_log[1].headers["x-tretu-app"] == "hollowmere" and http_log[1].headers["x-tretu-signature"]:match("^v1=%x+$") ~= nil)
res = tretu.rpc_account(ctx, '{"refresh":true}')
check("cached for a minute, forced refresh needs 15 s", res.state == "ok" and #http_log == 2)
clock_ms = clock_ms + 16000
http_answers = {{200, '{"balance":130}'}, {503, ""}}
res = tretu.rpc_account(ctx, '{"refresh":true}')
check("forced refresh after 15 s; unread kept when only the count fails", res.state == "ok" and res.balance == 130 and res.unread == 3 and #http_log == 4)
clock_ms = clock_ms + 61000
cache["tretu:platform:backoff"] = nil
http_answers = {{0}}
res = tretu.rpc_account(ctx, "{}")
check("outage -> last good value, marked stale", res.state == "stale" and res.balance == 130 and res.ageSec == 61)
check("outage starts the backoff", tretu.platform_backing_off())
local n_before = #http_log
res = tretu.rpc_account(ctx, "{}")
check("no platform call while backing off", #http_log == n_before and res.state == "stale")
cache["tretu:platform:backoff"] = nil
http_answers = {{404, '{"error":"user_not_found"}'}}
cache["tretu:summary:" .. SUB] = nil
res = tretu.rpc_account(ctx, "{}")
check("unknown sub is unavailable and no outage", res.state == "unavailable" and res.balance == nil and not tretu.platform_backing_off())
http_answers = {{raise = true}}
res = tretu.rpc_account(ctx, "{}")
check("a failing http call never raises out of the RPC", res.state == "unavailable")
cache["tretu:platform:backoff"] = nil
http_answers = {{200, '{"balance":"lots"}'}}
res = tretu.rpc_account(ctx, "{}")
check("malformed platform answer -> unavailable", res.state == "unavailable" and res.balance == nil)
local off = tretu.config({env = {TRETU_PLATFORM_BACKOFF_SEC = "0"}})
eq("backoff can be turned off", off.backoff_sec, 0)
eq("default backoff", tretu.config({env = {}}).backoff_sec, 15)

print(string.format("TRETU LUA TESTS: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
