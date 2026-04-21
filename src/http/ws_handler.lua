-- WebSocket upgrade handler.
--
-- The `websocket_relay` post-middleware reads the `X-WS-Relay` header from
-- this handler's response and routes the upgraded WebSocket connection to
-- the central relay hub (registered as "wippy.central" by wippy/relay's
-- central.lua). The central hub then spawns a per-user hub and dispatches
-- frames to the `echo_` plugin by `command_prefix`.
--
-- MVP: single-player local-only — we stamp `metadata.user_id = "local-player"`
-- so the central hub accepts the connection (it rejects joins with no user_id).

local http = require("http")
local json = require("json")

local function handler()
    local req = http.request()
    local res = http.response()

    local central_pid, err = process.registry.lookup("wippy.central")
    if err or not central_pid then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({ error = "relay central hub not registered" })
        return
    end

    res:set_header("X-WS-Relay", json.encode({
        target_pid = tostring(central_pid),
        message_topic = "ws.message",
        metadata = {
            user_id = "local-player",
        },
    }))
end

return { handler = handler }
