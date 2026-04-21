-- Probe target — trivial ping/pong responder used by the registry-xprocess
-- probe. Auto-started by the sibling process.service entry so the registry
-- lookup from probe.lua resolves a live PID at boot without any manual
-- spawn step.
--
-- Contract:
--   receives topic "ping" with payload { from = <probe_pid> }
--   replies via process.send(from, "pong", { from = process.pid() })

local logger = require("logger"):named("probe_target")

local function run(_args)
    local inbox = process.inbox()
    local events = process.events()

    -- Register by name so the probe process can resolve us via
    -- process.registry.lookup(). The process.service wrapper does not
    -- auto-register the entry ID — only explicit registry.register does.
    local reg_ok, reg_err = process.registry.register("app.probes:probe_target")
    if not reg_ok then
        logger:warn("[probe_target] registry.register failed", { error = tostring(reg_err) })
    end

    logger:info("[probe_target] started")

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
                local from = payload and payload.from
                if type(from) == "string" then
                    process.send(from, "pong", { from = process.pid() })
                end
            end

        elseif r.channel == events then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                return
            end
        end
    end
end

return { run = run }
