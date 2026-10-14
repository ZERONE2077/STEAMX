-- manifest.lua - multi-source manifest request code resolver (STEAMX)
-- Deployed to <Steam>/config/lua/manifest.lua
--
-- OpenSteamTool asks for fetch_manifest_code(gid) / fetch_manifest_code_ex(...)
-- before it falls back to the [manifest] url in opensteamtool.toml, so a file
-- here makes every known upstream available at once instead of forcing the user
-- to pick one and hope it stays up.
--
-- Why the retries are the point, measured 2026-09-23 from a CN/Tokyo line:
--   wudrm          http://gmrc.wudrm.com       ~10-43% per request  (openresty 503)
--   steamrun       https://manifest.steam.run  ~30% per request    (502)
--   opensteamtool  https://manifest.opensteamtool.com  0%          (Cloudflare 403)
-- The 503s are the origin shedding load, not a block: the client just has to
-- ask again. Four attempts turn a 43% source into a ~90% one.
--
-- Design rules:
--   * wudrm goes first: it is the only upstream that is plain HTTP, so it is the
--     one that works from mainland China without a proxy.
--   * No sleeps between attempts. Lua only exposes CPU time (os.clock), so a
--     delay would mean busy-waiting inside Steam's loader thread. Back-to-back
--     attempts already hit the retry window that matters.
--   * Never raise. An error thrown here aborts the whole manifest lookup, so
--     every call is wrapped in pcall and a dead end simply returns nil.
--   * Return the code as a *string*. Manifest GIDs exceed 2^53 and any float
--     round-trip would silently corrupt the last digits.
--
-- Source of truth for the copy embedded in main.ps1. After editing, re-pack it:
--   powershell -NoProfile -File tools\pack-manifest-lua.ps1

-- STEAMX-INJECT-BEGIN
local PREFERRED = "wudrm"
-- STEAMX-INJECT-END

local ATTEMPTS = {
    wudrm         = 4,
    steamrun      = 3,
    opensteamtool = 1,
}

local FALLBACK_ORDER = { "wudrm", "steamrun", "opensteamtool" }

local BASE_URL = {
    wudrm         = "http://gmrc.wudrm.com/manifest/",
    steamrun      = "https://manifest.steam.run/api/manifest/",
    opensteamtool = "https://manifest.opensteamtool.com/",
}

-- Only the opensteamtool endpoint carries a suffix. The toml that ships with OST
-- documents it as /{gid}, which answers 403 - the real path is /{gid}.wudrm.
local URL_SUFFIX = {
    opensteamtool = ".wudrm",
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
    local ok, body, status = pcall(getter, url)
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
