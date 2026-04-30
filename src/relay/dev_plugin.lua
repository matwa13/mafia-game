-- src/relay/dev_plugin.lua
-- Phase 5 dev telemetry relay plugin — D-DP-01 passive-mode runtime gate.
--
-- Always registered (auto_start: true) but dormant in product mode.
-- In product mode (MAFIA_DEV_MODE != "1"): no events.subscribe call, no
-- forwarding — plugin parks on inbox + proc_ev only. T-05-07 compliance.
--
-- In dev mode (MAFIA_DEV_MODE == "1"): subscribes to "mafia.dev" events
-- and forwards them to all connected SPA clients. On first connection,
-- sends a dev_status bootstrap frame so the SPA can render the seed input.
--
-- Frame contract (outbound, wrapped by websocket_relay as {topic, data}):
--   dev_status    { enabled: bool }                — connection bootstrap
--   dev_snapshot  { game_id, seed, round, phase,  — per-phase telemetry
--                   mafia_slots, roster, event_tail }
--
-- D-09 gate: all event-send calls live in src/lib/events.lua; this plugin
-- subscribes to "mafia.dev" but never publishes events directly.

local logger  = require("logger"):named("dev_plugin")
local events  = require("events")
local channel = require("channel")
local env     = require("env")

local function forward(conn_pid, frame_type, payload)
    -- websocket_relay wraps this as {topic: frame_type, data: payload}
    process.send(conn_pid, frame_type, payload)
end

local function run(_args)
    local inbox  = process.inbox()
    local proc_ev = process.events()
    local dev    = env.get("MAFIA_DEV_MODE") == "1"

    -- AP2: connection bookkeeping only.
    local conns  = {}       -- conn_pid -> { joined_at }
    local dev_sub = nil
    local dev_ch  = nil

    local function ensure_subscribed()
        -- D-DP-01: only subscribe in dev mode.
        if not dev then return end
        if dev_sub then return end
        dev_sub = events.subscribe("mafia.dev", "*")
        dev_ch  = dev_sub and dev_sub:channel() or nil
        logger:info("[dev_plugin] subscribed to mafia.dev")
    end

    local function unsubscribe()
        if dev_sub then dev_sub:close(); dev_sub = nil; dev_ch = nil end
    end

    ensure_subscribed()
    logger:info("[dev_plugin] started", { dev_mode = dev })

    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if dev_ch then cases[#cases + 1] = dev_ch:case_receive() end
        local r = channel.select(cases)
        if not r.ok then break end

        if r.channel == proc_ev then
            local ev = r.value
            if ev and ev.kind == process.event.CANCEL then
                unsubscribe()
                logger:info("[dev_plugin] CANCEL; exiting")
                return
            end

        elseif r.channel == inbox then
            -- Relay delivers inbound commands here. The payload carries conn_pid
            -- (same shape as game_plugin.lua:97 — relay strips the command_prefix).
            local msg     = r.value
            local payload = (msg and msg:payload() and msg:payload():data()) or {}
            local conn_pid = tostring(payload.conn_pid or "")
            if conn_pid ~= "" and not conns[conn_pid] then
                conns[conn_pid] = { joined_at = os.time() }
                -- D-SD-03: bootstrap dev_status on first connection so the SPA
                -- can render the Setup-screen seed input immediately.
                forward(conn_pid, "dev_status", { enabled = dev })
                logger:info("[dev_plugin] new conn; sent dev_status",
                    { conn_pid = conn_pid, enabled = dev })
            end
            -- Inbound dev_* commands are no-ops in v1; future commands extend here.

        elseif dev and dev_ch and r.channel == dev_ch then
            -- Forward dev event to all known connections.
            local evt = r.value
            if evt then
                -- evt.kind is e.g. "snapshot"; frame type becomes "dev_snapshot".
                local kind       = tostring(evt.kind or "")
                local frame_type = "dev_" .. kind
                local data       = evt.data or {}
                for cpid, _ in pairs(conns) do
                    process.send(cpid, frame_type, data)
                end
                logger:info("[dev_plugin] forwarded dev event",
                    { kind = kind, conn_count = (function()
                        local n = 0
                        for _ in pairs(conns) do n = n + 1 end
                        return n
                    end)() })
            end
        end
    end

    unsubscribe()
end

return { run = run }
