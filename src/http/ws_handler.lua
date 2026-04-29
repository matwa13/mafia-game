-- WebSocket upgrade handler.
--
-- The `websocket_relay` post-middleware reads the `X-WS-Relay` header from
-- this handler's response and routes the upgraded WebSocket connection to
-- the central relay hub (registered as "wippy.central" by wippy/relay's
-- central.lua). The central hub then spawns a per-user hub keyed on
-- metadata.user_id and dispatches frames by `command_prefix`.
--
-- Phase 8 changes (D-06..D-11):
--   * D-09 env-gate: env.get("MAFIA_AUTH_HEADER") nil  → dev mode, hardcoded
--                                                "local-player" (unchanged).
--                    env.get("MAFIA_AUTH_HEADER") set  → deploy mode, read
--                                                that header from the request.
--   * D-08 sanitizer: lowercase + alnum/-/_/  + ≤ 32 chars; reject reserved.
--   * D-11 origin gate: env.get("MAFIA_WS_ALLOWED_ORIGINS") (comma-separated)
--                       enforced HERE — RESEARCH K2: YAML cannot interpolate.

local http = require("http")
local json = require("json")
local env  = require("env")

-- D-08 (Phase 8): reject reserved names so a misconfigured Caddyfile (no
-- header_up, default empty header, or operator typo) cannot land every
-- teammate in the dev "local-player" game.
local RESERVED_IDS = { ["local-player"] = true }

-- D-08 (Phase 8): sanitize header-derived user_id.
-- Accepts only lowercase alphanumeric + - _ /; max 32 chars.
-- Returns nil on any rejection — caller sends HTTP 400.
local function sanitize_user_id(raw)
    if type(raw) ~= "string" then return nil end
    local id = raw:lower():match("^([%w%-_/]+)$")
    if not id or #id == 0 or #id > 32 then return nil end
    -- WR-01 fix (Phase 10): require at least one alphanumeric so '/',
    -- '////', '/local-player', '_', '____' are all rejected. Without this
    -- guard a misconfigured Caddy or upstream auth source could land every
    -- teammate in the same punctuation-only bucket (data-isolation break).
    if not id:find("%w") then return nil end
    if RESERVED_IDS[id] then return nil end
    return id
end

local function handler()
    local req = http.request()
    local res = http.response()

    -- D-11 (Phase 8): origin enforcement (env-driven, dev fallback).
    -- RESEARCH K2: ws_router.yaml post_options cannot interpolate env vars,
    -- so the real gate lives here. Comma-separated allowlist.
    local allowed_origins_str = env.get("MAFIA_WS_ALLOWED_ORIGINS")
        or "http://localhost:8080"
    local origin = req:header("Origin") or ""
    local allowed = {}
    for o in allowed_origins_str:gmatch("[^,]+") do
        local trimmed = o:match("^%s*(.-)%s*$")
        if trimmed ~= "" then allowed[trimmed] = true end
    end
    if not allowed[origin] then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({ error = "origin not allowed" })
        return
    end

    -- D-09 (Phase 8): dev mode → hardcoded; deploy mode → header-read.
    local auth_header_name = env.get("MAFIA_AUTH_HEADER")
    local user_id
    if auth_header_name then
        local raw = req:header(auth_header_name)
        if not raw or raw == "" then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:write_json({ error = "missing identity header" })
            return
        end
        user_id = sanitize_user_id(raw)
        if not user_id then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:write_json({ error = "invalid user identity" })
            return
        end
    else
        user_id = "local-player"  -- dev fallback
    end

    local central_pid, err = process.registry.lookup("wippy.central")
    if err or not central_pid then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({ error = "relay central hub not registered" })
        return
    end

    res:set_header("X-WS-Relay", json.encode({
        target_pid    = tostring(central_pid),
        message_topic = "ws.message",
        metadata      = { user_id = user_id },
    }))
end

return { handler = handler }
