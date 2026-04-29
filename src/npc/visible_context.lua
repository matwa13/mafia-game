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
    -- roster_names is the live per-game map {[slot]=name} from the orchestrator,
    -- populated at NPC spawn. WR-04 (Phase 3.1 polish): the legacy NPC-side
    -- roster fallback was deleted in Phase 10 — roster_names is the sole roster source.
    table.insert(lines, "===ROSTER===")
    local roster_names = state.roster_names
    if roster_names then
        for slot = 1, 6 do
            local name = roster_names[slot]
            if name and name ~= "" then
                table.insert(lines, "- " .. name)
            end
        end
    end
    table.insert(lines, "")

    -- 2. EVENT LOG WITH SCOPE-ASSERT PANIC (D-11).
    -- Render kind-aware narrative lines so the NPC's prompt reads like a
    -- game transcript:
    --   - chat.line        → "<speaker>: <text>"
    --   - night.resolved   → "[NIGHT round N] <victim> was killed — they were <role>."
    --   - player.eliminated → "[DAY round N] <victim> was voted out — they were <role>."
    --   - vote.tied        → "[DAY round N] Vote was tied — no elimination."
    --   - other kinds      → fall back to legacy "<kind>: <text>".
    local function name_of(slot)
        if not slot then return "someone" end
        if roster_names and roster_names[slot] then return roster_names[slot] end
        return "slot-" .. tostring(slot)
    end

    table.insert(lines, "===EVENTS===")
    for _, event in ipairs(state.event_log or {}) do
        assert(pe.scope_allowed(state.role, event.scope),
            string.format("SCOPE LEAK: npc=%s role=%s event.scope=%s kind=%s",
                npc_id,
                tostring(state.role),
                tostring(event.scope),
                tostring(event.kind)))

        if event.kind == "chat.line" and event.from_slot then
            table.insert(lines, name_of(event.from_slot) .. ": " .. (event.text or ""))

        elseif event.kind == "night.resolved" and event.victim_slot then
            local round_str = event.round and ("round " .. tostring(event.round)) or "night"
            local role_str  = event.revealed_role
                and (" — they were " .. tostring(event.revealed_role))
                or ""
            table.insert(lines,
                "[NIGHT " .. round_str .. "] " .. name_of(event.victim_slot)
                .. " was killed" .. role_str .. ".")

        elseif event.kind == "player.eliminated" and event.victim_slot then
            local round_str = event.round and ("round " .. tostring(event.round)) or "day"
            local role_str  = event.revealed_role
                and (" — they were " .. tostring(event.revealed_role))
                or ""
            local cause_str = event.cause == "night" and "killed at night" or "voted out"
            table.insert(lines,
                "[DAY " .. round_str .. "] " .. name_of(event.victim_slot)
                .. " was " .. cause_str .. role_str .. ".")

        elseif event.kind == "vote.tied" then
            local round_str = event.round and ("round " .. tostring(event.round)) or "day"
            table.insert(lines,
                "[DAY " .. round_str .. "] Vote was tied — no elimination.")

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
