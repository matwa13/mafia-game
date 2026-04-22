-- src/game/game_manager.lua
-- Phase 2 Plan 01: game_manager singleton skeleton.
-- D-01: long-lived `process.service` registered as `app.game:game_manager`.
-- D-05: trap_links=true so we can observe orchestrator DOWN signals (Plan 04).
-- D-06: clean-end path (explicit child cancel on this service's own shutdown)
-- lands in Plan 04; Plan 01 ships the inbox/proc_ev main loop only.
-- Note: `process.service` does NOT auto-register this process's ID —
-- explicit `process.registry.register` below (Phase 0 Plan 05 decision).

local logger = require("logger"):named("game_manager")
local time = require("time")
local channel = require("channel")

local function run(_args)
    -- 1. Register by well-known name. process.service does NOT do this.
    local reg_ok, reg_err = process.registry.register("app.game:game_manager")
    if not reg_ok then
        logger:error("[game_manager] registry.register failed",
            { err = tostring(reg_err) })
        return
    end

    -- 2. Enable trap_links so LINK_DOWN from dynamically-spawned orchestrators
    --    arrives on our process.events() channel (Plan 04 handles it).
    process.set_options({ trap_links = true })

    -- 3. Supervisor state. Plan 02 populates state.active_games on game.start.
    local state = {}
    state.active_games = {}  -- game_id (string) -> { orch_pid, driver_pid, handled = false }

    local inbox = process.inbox()
    local proc_ev = process.events()

    logger:info("[game_manager] online", { registry = "app.game:game_manager" })

    -- 4. Main loop — channel.select over inbox + process.events.
    --    Plan 02 adds the game.start spawn path; Plan 04 adds EXIT/LINK_DOWN
    --    dispatch (abandoned-game bookkeeping). Plan 01 logs receipts only.
    while true do
        local r = channel.select({
            inbox:case_receive(),
            proc_ev:case_receive(),
        })
        if not r.ok then
            logger:warn("[game_manager] channel.select closed; exiting")
            break
        end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local payload = msg:payload():data()

            if topic == "game.start" then
                -- Plan 02 replaces this body with: mint uuid.v4(), INSERT games,
                -- spawn_linked_monitored orchestrator, wait for orchestrator.ready,
                -- reply game.started to driver. Plan 01 logs + placeholder ack.
                logger:info("[game_manager] game.start received (skeleton)",
                    { payload = tostring(payload) })
                local driver_pid = payload and payload.driver_pid
                if type(driver_pid) == "string" then
                    process.send(driver_pid, "game.started",
                        { skeleton = true, error = "not-yet-implemented" })
                end

            elseif topic == "orchestrator.ready" then
                -- Plan 02 will forward game.started to the driver here.
                logger:info("[game_manager] orchestrator.ready (skeleton)")

            else
                logger:debug("[game_manager] unhandled topic",
                    { topic = tostring(topic) })
            end

        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                logger:info("[game_manager] CANCEL received; exiting cleanly")
                break
            end
            -- Plan 04 wires EXIT / LINK_DOWN dispatch with `handled` dedupe
            -- (Pitfall 4: spawn_linked_monitored fires BOTH signals on crash).
            logger:debug("[game_manager] proc event (skeleton)",
                { kind = tostring(event and event.kind) })
        end
    end

    -- Plan 04 adds the explicit child-cancel cascade here (Pitfall 3).
    return { status = "shutdown" }
end

return { run = run }
