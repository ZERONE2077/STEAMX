-- manifest.lua - multi-source manifest request code resolver (STEAMX)
-- Deployed to <Steam>/config/lua/manifest.lua
--
-- OpenSteamTool asks for fetch_manifest_code(gid) / fetch_manifest_code_ex(...)
-- before it falls back to the [manifest] url in opensteamtool.toml, so a file
-- here makes every known upstream available at once instead of forcing the user
-- to pick one and hope it stays up.
--
-- Verified contract (read from OST 1.5.3.5 src/Utils/SteamMetadata/ManifestClient.cpp):
--   * fetch_manifest_code_ex(app_id, depot_id, gid) is tried FIRST when both
--     app_id and depot_id are non-zero, then fetch_manifest_code(gid).
--   * A non-nil return wins immediately; nil falls through to the toml source.
--   * The shared lua_State is guarded by an internal mutex, and that lock is
--     released before any network I/O, so blocking in here does not serialise
--     other depots' requests.
--   * http_get(url [, headers]) -> body, status_code. The optional 2nd argument
--     IS honoured (LuaConfig.cpp: lua_gettop(L) >= 2), which is what makes the
--     manifestdex User-Agent requirement solvable at all - see below.
--
-- Measured 2026-10-15 on this machine, 5 rounds each, real gid=10542579308:
--   manifestdex      5/5 HTTP 200   337-357ms   (needs UA: ManifestDeX/1.0)
--   wudrm            4/5 then 0/5   -           (flips between 200 and 403/503)
--   steamrun         2/5 HTTP 200   1058-1791ms (502 the rest)
--   opensteamtool    0/5 HTTP 403   -           (rejects non-browser clients)
--   wudrm / steamrun / opensteamtool are all unreliable here; retries are the
--   whole point of this file, not a nicety.
--
-- !! The numbers above were taken with the local CrossProxy TUN active, which
--    fake-ip-hijacks DNS (every upstream resolved to 198.18.0.x). Latency is
--    therefore NOT a domestic-CN measurement. Only the HTTP status reliability
--    is trustworthy, and that is exactly what the ordering below relies on.
--
-- Design rules:
--   * manifestdex goes first: it is the only source measured to answer 200 on
--     every attempt. It REQUIRES the User-Agent "ManifestDeX/1.0" - without it
--     the host answers 403, which is why the header is sent explicitly rather
--     than left to WinHttpOpen's default "OpenSteamTool/1.0".
--   * wudrm second: it is the only upstream that is plain HTTP, so it is the one
--     that can work from mainland China without a proxy. It is flaky, hence the
--     generous retry count.
--   * opensteamtool is attempted last and only once: every measurement returned
--     403, and the toml that ships with OST documents the wrong path for it.
--   * No sleeps between attempts. Lua only exposes CPU time (os.clock), so a
--     delay would mean busy-waiting on Steam's loader thread. Back-to-back
--     attempts already hit the retry window that matters.
--   * Never raise. An error thrown here aborts the whole manifest lookup, so
--     every call is wrapped in pcall and a dead end simply returns nil.
--   * Return the code as a *string*. Manifest GIDs exceed 2^53 and any float
--     round-trip would silently corrupt the last digits.

-- STEAMX-INJECT-BEGIN
local PREFERRED = "manifestdex"
-- STEAMX-INJECT-END

local ATTEMPTS = {
    manifestdex   = 3,
    wudrm         = 5,
    steamrun      = 3,
    opensteamtool = 1,
}

local FALLBACK_ORDER = { "manifestdex", "wudrm", "steamrun", "opensteamtool" }

local BASE_URL = {
    manifestdex   = "https://manifest.manifestdex.com/",
    wudrm         = "http://gmrc.wudrm.com/manifest/",
    steamrun      = "https://manifest.steam.run/api/manifest/",
    opensteamtool = "https://manifest.opensteamtool.com/",
}

-- Only the opensteamtool endpoint carries a suffix. The toml that ships with OST
-- documents it as /{gid}, which answers 403 - the real path is /{gid}.wudrm.
-- (Both shapes returned 403 in the 2026-10-15 measurements, so this stays last.)
local URL_SUFFIX = {
    opensteamtool = ".wudrm",
}

-- manifestdex rejects the WinHttp default agent outright; this exact string is
-- the only one measured to get a 200.
local HEADERS = {
    manifestdex = { ["User-Agent"] = "ManifestDeX/1.0" },
}

local MAX_GID_DIGITS = 20
local cache = {}

-- OpenSteamTool hands the gid over as an integer, but a float would stringify as
-- "1.0570517747115e+19" and break the URL, so normalise before use.
local function to_gid_string(gid)
    if type(gid) == "string" then
        local trimmed = gid:gsub("%s+", "")
        if trimmed == "" then return nil end
        return trimmed
    end
    if type(gid) == "number" then
        if math.type and math.type(gid) == "integer" then
            return tostring(gid)
        end
        return string.format("%.0f", gid)
    end
    return nil
end

-- wudrm and opensteamtool answer with a bare uint64; steamrun wraps it in JSON.
-- Anything else - notably an HTML error page - has to fail loudly enough to be
-- retried, so the body is matched strictly instead of being returned as-is.
local function parse_code(body)
    if type(body) ~= "string" then return nil end
    local code = body:match('"content"%s*:%s*"(%d+)"')
    if not code then
        code = body:match("^%s*(%d+)%s*$")
    end
    if not code then return nil end
    if #code > MAX_GID_DIGITS or code == "0" then return nil end
    return code
end

local function build_order()
    local list = {}
    local seen = {}
    if type(PREFERRED) == "string" and ATTEMPTS[PREFERRED] then
        list[#list + 1] = PREFERRED
        seen[PREFERRED] = true
    end
    for _, name in ipairs(FALLBACK_ORDER) do
        if not seen[name] then
            list[#list + 1] = name
            seen[name] = true
        end
    end
    return list
end

local ORDER = build_order()

local function request(provider, gid)
    local getter = http_get
    if type(getter) ~= "function" then return nil end
    local url = BASE_URL[provider] .. gid .. (URL_SUFFIX[provider] or "")
    local headers = HEADERS[provider]

    -- Call with headers only when the provider needs them: the 2-argument form
    -- is supported (LuaConfig.cpp checks lua_gettop >= 2) but an older build may
    -- reject it, so the plain form stays the default path.
    local ok, body, status
    if headers then
        ok, body, status = pcall(getter, url, headers)
        if not ok then
            ok, body, status = pcall(getter, url)
        end
    else
        ok, body, status = pcall(getter, url)
    end

    if not ok or status ~= 200 then return nil end
    return parse_code(body)
end

local function resolve(gid)
    local key = to_gid_string(gid)
    if not key or #key > MAX_GID_DIGITS then return nil end

    local hit = cache[key]
    if hit then return hit end

    for _, provider in ipairs(ORDER) do
        for _ = 1, (ATTEMPTS[provider] or 1) do
            local code = request(provider, key)
            if code then
                cache[key] = code
                return code
            end
        end
    end
    return nil
end

local function resolve_safely(gid)
    local ok, code = pcall(resolve, gid)
    if ok then return code end
    return nil
end

function fetch_manifest_code(gid)
    return resolve_safely(gid)
end

function fetch_manifest_code_ex(app_id, depot_id, gid)
    return resolve_safely(gid)
end
