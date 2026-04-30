-- src/npc/turn_side_chat.lua
-- D-05 (Phase 6): Mafia night side-chat turn handler — run_night_side_chat.
-- Phase 7: migrated from wippy/llm structured output to agent runner:step (Approach A schema-as-tool).
-- Schema lives in src/npc/agents/_index.yaml (side_chat_tool entry).
-- LOOP-03 + the mafia scope routing non-negotiable: side-chat events carry scope="mafia";
-- villager NPCs never subscribe to mafia.mafia so the private channel is enforced.
-- Strict alternation enforced by orchestrator: exactly one night.side_chat per turn,
-- waits for reply before re-enabling human input. Persona drift tripwire fires first.

local logger    = require("logger"):named("turn_side_chat")
local time      = require("time")
local sql       = require("sql")
local json      = require("json")
local pe        = require("pe")
local prompt    = require("prompt")
local prompts   = require("prompts")
local errors    = require("errors")
local event_log = require("event_log")

-- Phase 7: MODEL constant removed - model is set in agent definition (npc.lua ctx:load_agent).
local VOTE_CAP_S = "15s"

-- Phase 7: SIDE_CHAT_SCHEMA moved to src/npc/agents/_index.yaml (side_chat_tool meta.input_schema).

local function run_night_side_chat(state, raw)
    prompts.assert_stable_hash(state)
    state.round = (raw.round and tonumber(raw.round)) or state.round or 0
    local round = state.round
    local parent_pid = tostring(state.parent_pid)

    -- Pull living_target_slots/names + side_chat_history (recent partner exchange).
    local living_target_slots = {}
    local living_target_names = {}
    local side_chat_history = {}
    for k, v in pairs(raw) do
        if k == "living_target_slots" then living_target_slots = v end
        if k == "living_target_names" then living_target_names = v end
        if k == "side_chat_history" then side_chat_history = v end
    end
    local fallback_slot = nil
    if type(living_target_slots) == "table" and #living_target_slots > 0 then
        fallback_slot = tonumber(living_target_slots[1])
    end

    -- Phase 7: user-message-only conversation. Agent runner injects system prompt.
    local p = prompt.new()
    local visible_context = require("visible_context")
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        suspicion = state.suspicion,
        roster_names = state.roster_names,
        slot = state.slot,
    }, "chat")

    -- Render side-chat history inline (recent partner exchange this round).
    local chat_lines = {}
    for _, m in ipairs(side_chat_history or {}) do
        local from = tostring(m.from or "?")
        local txt = tostring(m.text or "")
        if txt ~= "" then chat_lines[#chat_lines + 1] = from .. ": " .. txt end
    end
    local chat_str = table.concat(chat_lines, "\n")

    local names_str = table.concat(living_target_names or {}, ", ")
    local slot_strs = {}
    for _, x in ipairs(living_target_slots or {}) do
        slot_strs[#slot_strs + 1] = tostring(x)
    end
    local slots_str = table.concat(slot_strs, ", ")
    local directive = string.format(
        "\n\n===MAFIA SIDE-CHAT===\nYou are Mafia, talking to your partner privately. Night %d.\n"
        .. "Living non-Mafia targets: %s (slots: %s)\n"
        .. "Recent exchange:\n%s\n\n"
        .. "Reply with ONE short message (1-2 sentences) AND your current target suggestion (slot number).\n"
        .. "Stay in character. The suggestion can change as you discuss.",
        round, names_str, slots_str, chat_str)
    p:add_user(tail .. directive)

    assert(state.tool_runner ~= nil, "tool_runner missing — npc.lua init order broken")
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        -- Phase 7 D-12-FALLBACK + Approach A: named tool_call forces
        -- reply_mafia_side_chat (llm_alias of side_chat_tool). Uses tool_runner
        -- (per-NPC second runner with the three schema-as-tool entries).
        local res, err = errors.with_retry(state.npc_id, "side_chat", function()
            return state.tool_runner:step(p, { tool_call = "reply_mafia_side_chat" })
        end)
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        errors.persist_error(state.npc_id, "side_chat", { type = "TIMEOUT", message = tostring(VOTE_CAP_S) }, 0)
        process.send(parent_pid, "night.side_chat.reply", {
            from_slot = state.slot,
            side_chat_text = "[side-chat unavailable]",
            suggested_target_slot = fallback_slot,
            reasoning = "llm_timeout",
            round = round,
        })
        return
    end

    local rv = r.value
    local rv_err, rv_res = nil, nil
    for k, v in pairs(rv) do
        if k == "err" then rv_err = v end
        if k == "res" then rv_res = v end
    end
    if rv_err then
        errors.persist_error(state.npc_id, "side_chat", rv_err, 0)
        process.send(parent_pid, "night.side_chat.reply", {
            from_slot = state.slot,
            side_chat_text = "[side-chat unavailable]",
            suggested_target_slot = fallback_slot,
            reasoning = "llm_error",
            round = round,
        })
        return
    end

    -- Phase 7: structured args at response.tool_calls[1].arguments (Lua table).
    local res_table = {}
    if type(rv_res) == "table" and type(rv_res.tool_calls) == "table"
       and type(rv_res.tool_calls[1]) == "table"
       and type(rv_res.tool_calls[1].arguments) == "table" then
        res_table = rv_res.tool_calls[1].arguments
    end

    local side_chat_text        = tostring(res_table.side_chat_text or "")
    local suggested_target_slot = res_table.suggested_target_slot and tonumber(res_table.suggested_target_slot) or nil
    local reasoning             = tostring(res_table.reasoning or "")

    -- Defensive: keep suggestion in the living-target list; fall back if not.
    local valid = false
    for _, slot in ipairs(living_target_slots or {}) do
        if tonumber(slot) == suggested_target_slot then valid = true; break end
    end
    if not valid then suggested_target_slot = fallback_slot end

    process.send(parent_pid, "night.side_chat.reply", {
        from_slot = state.slot,
        side_chat_text = side_chat_text,
        suggested_target_slot = suggested_target_slot,
        reasoning = reasoning,
        round = round,
    })
end

return {
    run_night_side_chat = run_night_side_chat,
}
