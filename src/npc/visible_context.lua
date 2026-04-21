-- src/npc/visible_context.lua
-- D-11 + D-12: Scope+role filter with inline panic on cross-scope leak.
-- This is the ONLY place an NPC prompt is built from events.
-- Suspicion state (D-16) is NOT read here — only in vote-turn rendering.

local pe = require("pe")

local function visible_context(npc_id, state)
    local lines = {}
    for _, event in ipairs(state.event_log) do
        assert(pe.scope_allowed(state.role, event.scope),
            string.format("SCOPE LEAK: npc=%s role=%s event.scope=%s kind=%s",
                npc_id,
                tostring(state.role),
                tostring(event.scope),
                tostring(event.kind)))
        table.insert(lines, event.kind .. ": " .. (event.text or ""))
    end
    return table.concat(lines, "\n")
end

return visible_context
