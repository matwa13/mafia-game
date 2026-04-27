-- src/game/dev_telemetry.lua
-- D-22: MAFIA_DEV_MODE env flag + dev_event ring buffer + dev_snapshot request/emit.
-- Phase 5 success criterion: dev-only relay plugin receives mafia.dev events from
-- emit_dev_snapshot; this file is the sole emitter of those frames.
-- D-DP-10: ring buffer capacity hard-capped at DEV_EVENT_TAIL_CAP (20).

local logger  = require("logger"):named("dev_telemetry")
local time    = require("time")
local channel = require("channel")
local env     = require("env")
local pe      = require("pe")

local function dev_mode()
    return env.get("MAFIA_DEV_MODE") == "1"
end

-- D-DP-10: ring buffer of recent {scope, kind, path, ts} records.
-- Populated on every pe.publish_event / pe.publish_dev_event call site via
-- append_dev_event(state, ...). Capacity hard-capped at 20 (oldest overwritten).
-- CONSTRAINT: call request_dev_snapshots only when inbox is otherwise idle
-- (between phase transitions). The FSM is structured this way already.
local DEV_EVENT_TAIL_CAP = 20

local function append_dev_event(state, scope, kind, path)
    -- 1-based slot; modular index wraps at DEV_EVENT_TAIL_CAP.
    local idx = (state.dev_event_tail_idx % DEV_EVENT_TAIL_CAP) + 1
    state.dev_event_tail[idx] = {
        scope = scope, kind = kind, path = path, ts = os.time(),
    }
    state.dev_event_tail_idx = state.dev_event_tail_idx + 1
end

-- Returns the ring buffer as a chronologically-ordered array (oldest → newest).
local function snapshot_dev_event_tail(state)
    local out = {}
    local total = state.dev_event_tail_idx
    if total == 0 then return out end
    local count = math.min(total, DEV_EVENT_TAIL_CAP)
    local start = (total - count) % DEV_EVENT_TAIL_CAP
    for i = 0, count - 1 do
        local slot = ((start + i) % DEV_EVENT_TAIL_CAP) + 1
        out[#out + 1] = state.dev_event_tail[slot]
    end
    return out
end

-- D-DP-05: collect per-NPC telemetry via unicast process.send.
-- Mirrors gather_readiness pattern (lines ~163-181): 500ms deadline, marks
-- missing slots as {slot, unavailable=true}. Only call between phase transitions.
local function request_dev_snapshots(state)
    local cap = "500ms"
    local replies = {}
    local pending = {}
    for slot, pid in pairs(state.npc_pids or {}) do
        if type(pid) == "string" then
            process.send(pid, "dev.snapshot.request", { round = state.round, phase = state.phase })
            pending[slot] = true
        end
    end
    local inbox = process.inbox()
    local deadline = time.after(cap)
    local pending_count = 0
    for _ in pairs(pending) do pending_count = pending_count + 1 end
    while pending_count > 0 do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel ~= inbox then break end
        local msg = r.value
        local topic_ok, topic = pcall(function() return msg:topic() end)
        if topic_ok and topic == "dev.snapshot.reply" then
            local data = (msg:payload() and msg:payload():data()) or {}
            local dslot = data.slot
            if dslot and pending[dslot] then
                -- Use string keys so Wippy's JSON encoder treats roster as a
                -- map. Slot 1 is the human (no NPC), so integer keys would be
                -- sparse {2,3,4,5,6} and the http.ws transcoder rejects sparse
                -- arrays ("non-contiguous numeric keys"), closing the WS.
                replies[tostring(dslot)] = data
                pending[dslot] = nil
                pending_count = pending_count - 1
            end
        end
        -- non-reply messages dropped; this function is only called between transitions
    end
    -- Fill identity fields from orchestrator-owned state for any slot that
    -- didn't reply within the deadline. Two real causes of no-reply:
    --   1. Voted-out NPCs whose process has exited (no one to answer).
    --   2. Alive NPCs busy in a multi-second llm.generate call (their main
    --      loop won't read dev.snapshot.request until the call returns).
    -- Without this fill the SPA card shows "—" for name/role/alive even
    -- though the orchestrator already knows those values. Live telemetry
    -- (suspicion, prompt digest, last vote/pick/error) stays absent.
    for slot in pairs(pending) do
        local persona = state.slot_persona and state.slot_persona[slot] or nil
        replies[tostring(slot)] = {
            slot        = slot,
            unavailable = true,
            name        = (state.roster_names and state.roster_names[slot]) or (persona and persona.name) or nil,
            role        = state.roles and state.roles[slot] or nil,
            alive       = state.alive and state.alive[slot] == true or false,
            archetype   = persona and persona.archetype or nil,
        }
    end
    return replies
end

-- D-DP-03/D-DP-06: emit a dev.snapshot event after each phase transition.
-- Collects NPC telemetry, aggregates roster + mafia_slots + event_tail.
local function emit_dev_snapshot(state)
    if not dev_mode() then return end
    local roster = request_dev_snapshots(state)
    local mafia_slots = {}
    for s, r in pairs(state.roles or {}) do
        if r == "mafia" then mafia_slots[#mafia_slots + 1] = s end
    end
    table.sort(mafia_slots)
    pe.publish_dev_event("snapshot", "/" .. state.game_id, {
        game_id     = state.game_id,
        seed        = state.rng_seed,
        round       = state.round,
        phase       = state.phase,
        mafia_slots = mafia_slots,
        roster      = roster,
        event_tail  = snapshot_dev_event_tail(state),
    })
    append_dev_event(state, "dev", "snapshot", "/" .. state.game_id)
end

return {
    dev_mode = dev_mode,
    append_dev_event = append_dev_event,
    snapshot_dev_event_tail = snapshot_dev_event_tail,
    request_dev_snapshots = request_dev_snapshots,
    emit_dev_snapshot = emit_dev_snapshot,
}
