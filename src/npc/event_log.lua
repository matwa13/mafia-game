-- src/npc/event_log.lua
-- D-05 (Phase 6): NPC event log helpers — unpack, render, append.
-- AP5 non-negotiable: NPC stores chat history only via SQL rehydrate (orchestrator
-- is the sole writer of `messages`); NPCs accumulate a per-process event_log in RAM
-- that is rebuilt by replaying subscription events. No SQL writes from this file.
-- EVENT_LOG_CAP (200): soft cap to prevent unbounded growth (T-03-02-06).

local logger = require("logger"):named("event_log")
local json   = require("json")

local EVENT_LOG_CAP = 200

--- unpack_event — extract (kind, data) from a subscription-channel event
--- via pairs() to bypass the linter's process.Event narrowing.
local function unpack_event(evt)
    if type(evt) ~= "table" then return nil, nil end
    local kind, data
    for k, v in pairs(evt) do
        if k == "kind" then kind = v end
        if k == "data" then data = v end
    end
    return kind, data
end

local function event_to_log_entry(kind, data)
    local scope, text, from_slot, victim_slot, revealed_role, cause, round_num
    if type(data) == "table" then
        for k, v in pairs(data) do
            if k == "scope" then scope = v end
            if k == "text" then text = v end
            if k == "message" and not text then text = v end
            if k == "from_slot" then from_slot = v end
            if k == "victim_slot" then victim_slot = v end
            if k == "revealed_role" then revealed_role = v end
            if k == "cause" then cause = v end
            if k == "round" then round_num = v end
        end
    end
    return {
        scope = scope,
        kind = kind,
        text = text or "",
        from_slot = from_slot,
        victim_slot = victim_slot,
        revealed_role = revealed_role,
        cause = cause,
        round = round_num,
    }
end

local function append_event(state, entry)
    table.insert(state.event_log, entry)
    -- Soft cap: evict oldest entries to prevent unbounded growth (T-03-02-06).
    if #state.event_log > EVENT_LOG_CAP then
        table.remove(state.event_log, 1)
    end
end

return {
    unpack_event       = unpack_event,
    event_to_log_entry = event_to_log_entry,
    append_event       = append_event,
}
