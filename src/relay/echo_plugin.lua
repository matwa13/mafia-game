-- Echo relay plugin.
--
-- Structural template that later plugins (game_, dev_) copy-rename. Holds
-- ONLY connection bookkeeping per CLAUDE.md AP2: NO domain state.
--
-- Wire-up (for context):
--   client → ws://:8080/ws/
--   → websocket_relay (post_middleware on app.http:ws_router)
--   → reads X-WS-Relay header from ws_handler.lua → target_pid = wippy.central
--   → central hub spawns a per-user hub (wippy.relay:user) with user_id="local-player"
--   → user hub sees our meta.type=relay.plugin + command_prefix="echo_" entry
--     and spawns THIS process on first frame with type="echo_..."
--   → for each "echo_*" frame, user hub strips the prefix and sends us:
--       topic = "ping"  (post-strip)
--       payload = { conn_pid, type = "echo_ping", data = {...}, ... }
--   → we reply with process.send(conn_pid, "echo_pong", {...data object...})
--     which the middleware wraps as `{"topic":"echo_pong","data":{...}}`
--     text frame to the browser.

local logger = require("logger"):named("echo_plugin")

local function run(args)
    local inbox = process.inbox()
    local events = process.events()

    -- AP2-compliant: only mutable state here is connection bookkeeping.
    -- Map of conn_pid (string) → { joined_at: epoch }. Populated lazily on
    -- first ping from a connection; user hub does not forward ws.join/leave
    -- to plugins, so lazy-tracking is the best we can do here.
    local conns = {}
    local first_ping_logged = false

    logger:info("started; awaiting relay frames", {
        user_id = args and args.user_id or nil,
    })

    while true do
        local r = channel.select({
            inbox:case_receive(),
            events:case_receive(),
        })

        if not r.ok then
            break
        end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local payload = msg:payload():data()

            if topic == "ping" then
                -- command_prefix "echo_" stripped → incoming topic is "ping"
                local conn_pid = payload and payload.conn_pid
                if type(conn_pid) ~= "string" then
                    logger:warn("ping without string conn_pid; dropping")
                else
                    -- Track connection bookkeeping (first sighting of this conn_pid).
                    if not conns[conn_pid] then
                        conns[conn_pid] = { joined_at = os.time() }
                    end

                    -- Echo back. The websocket_relay middleware serializes
                    -- outbound `process.send(client_pid, topic, payload)`
                    -- as a text frame shaped `{"topic": <topic>, "data":
                    -- <payload>}`. So we use topic = "echo_pong" (full
                    -- type string) and payload = the data object only.
                    local client_ts = payload.data and payload.data.ts
                    process.send(conn_pid, "echo_pong", {
                        ts = client_ts,
                        echoed = true,
                    })

                    if not first_ping_logged then
                        -- Plugin-internal sticky marker. Distinct from the
                        -- probe namespace owned by a later plan (see D-05).
                        logger:info("[echo_plugin] first echo_ping received")
                        first_ping_logged = true
                    end
                end
            else
                -- Unknown post-strip topic under the echo_ prefix.
                logger:warn("unknown topic; dropping", { topic = tostring(topic) })
            end

        elseif r.channel == events then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                logger:info("cancelled; exiting")
                return
            end
        end
    end
end

return { run = run }
