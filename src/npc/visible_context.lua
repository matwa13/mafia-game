-- src/npc/visible_context.lua
-- D-11 + D-12: Scope+role filter with inline panic on cross-scope leak.
-- This is the ONLY place an NPC prompt is built from events.
-- Phase 3: adds roster block (NPC-06) and vote-mode suspicion render (mode arg).

local pe = require("pe")

local function visible_context(npc_id, state, mode)
    -- Normalise mode: accept "vote" or default to "chat".
    local render_mode = (mode == "vote") and "vote" or "chat"
    local lines = {}

    -- 1. ROSTER BLOCK (NPC-06 — NPCs need names to address each other).
    -- Prefer state.roster_names (the live per-game map from the orchestrator,
    -- {[slot]=name}) because state.roster is currently always empty (WR-04).
    -- Fallback to state.roster only for legacy callers that pre-populate it.
    table.insert(lines, "===ROSTER===")
    local roster_names = state.roster_names
    if roster_names and next(roster_names) ~= nil then
        for slot = 1, 6 do
            local name = roster_names[slot]
            if name and name ~= "" then
                table.insert(lines, "- " .. name)
            end
        end
    else
        for _, entry in ipairs(state.roster or {}) do
            if entry.alive then
                table.insert(lines, "- " .. entry.name .. " (alive)")
            else
                table.insert(lines, "- " .. entry.name .. " (eliminated)")
            end
        end
    end
    table.insert(lines, "")

    -- 2. EVENT LOG WITH SCOPE-ASSERT PANIC (D-11).
    -- Chat lines render as "<speaker>: <text>" so the NPC can distinguish
    -- who said what — including the human player's interjections. Other
    -- events (night.resolved, player.eliminated, chat_locked, etc.) keep
    -- the legacy "<kind>: <text>" render since they aren't person-bound.
    table.insert(lines, "===EVENTS===")
    for _, event in ipairs(state.event_log or {}) do
        assert(pe.scope_allowed(state.role, event.scope),
            string.format("SCOPE LEAK: npc=%s role=%s event.scope=%s kind=%s",
                npc_id,
                tostring(state.role),
                tostring(event.scope),
                tostring(event.kind)))
        if event.kind == "chat.line" and event.from_slot and roster_names then
            local speaker = roster_names[event.from_slot]
                or ("slot-" .. tostring(event.from_slot))
            table.insert(lines, speaker .. ": " .. (event.text or ""))
        else
            table.insert(lines, event.kind .. ": " .. (event.text or ""))
        end
    end

    -- 3. SUSPICION (render_mode == "vote" ONLY — D-16: suspicion is vote-only)
    if render_mode == "vote" and state.suspicion then
        table.insert(lines, "")
        table.insert(lines, "===YOUR PRIVATE SUSPICION STATE===")
        for slot, entry in pairs(state.suspicion) do
            local value, note
            if type(entry) == "table" then
                value = entry.value
                note  = entry.reflection_note
            else
                value = entry
            end
            local name = (state.roster_names and state.roster_names[slot]) or ("slot-" .. tostring(slot))
            if note and note ~= "" then
                table.insert(lines, string.format("- %s: %d/100 — %s", name, value, note))
            else
                table.insert(lines, string.format("- %s: %d/100", name, value))
            end
        end
    end

    return table.concat(lines, "\n")
end

return visible_context
