-- src/npc/turn_side_chat.lua
-- D-05 (Phase 6): Mafia night side-chat turn handler — run_night_side_chat.
-- LOOP-03 + the mafia scope routing non-negotiable: side-chat events carry scope="mafia";
-- villager NPCs never subscribe to mafia.mafia so the private channel is enforced.
-- Strict alternation enforced by orchestrator: exactly one night.side_chat per turn,
-- waits for reply before re-enabling human input. Persona drift tripwire fires first.

local logger    = require("logger"):named("turn_side_chat")
local time      = require("time")
local sql       = require("sql")
local json      = require("json")
local llm       = require("llm")
local pe        = require("pe")
local prompt    = require("prompt")
local prompts   = require("prompts")
local errors    = require("errors")
local event_log = require("event_log")

local MODEL      = "claude-haiku-4-5"
local VOTE_CAP_S = "15s"

-- LOOP-03: Mafia partner side-chat turn — one structured_output call per turn.
-- Partner emits a short side-chat line PLUS a current target suggestion. The
-- suggestion may evolve across turns as the human pushes back; the SPA's
-- "Partner picks: X" badge updates each time.
local SIDE_CHAT_SCHEMA = {
    type = "object",
    properties = {
        side_chat_text = {
            type = "string",
            maxLength = 200,
            description = "What you say to your partner (1-2 sentences max). In character.",
        },
        suggested_target_slot = {
            type = "integer",
            description = "Slot of living non-Mafia player you currently suggest targeting.",
        },
        reasoning = {
            type = "string",
            maxLength = 200,
            description = "Internal reasoning (not shown to partner). Why this target?",
        },
    },
    required = { "side_chat_text", "suggested_target_slot", "reasoning" },
    additionalProperties = false,
}

local function run_night_side_chat(state, raw)
    prompts.assert_stable_hash(state)
    state.round = (raw.round and tonumber(raw.round)) or state.round or 0
    local round = state.round

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

    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()

    local visible_context = require("visible_context")
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
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

    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.structured_output(SIDE_CHAT_SCHEMA, p, { model = MODEL })
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        errors.persist_error(state.npc_id, "side_chat", { type = "TIMEOUT", message = tostring(VOTE_CAP_S) }, 0)
        process.send(state.parent_pid, "night.side_chat.reply", {
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
        process.send(state.parent_pid, "night.side_chat.reply", {
            from_slot = state.slot,
            side_chat_text = "[side-chat unavailable]",
            suggested_target_slot = fallback_slot,
            reasoning = "llm_error",
            round = round,
        })
        return
    end

    local res_table = {}
    if type(rv_res) == "table" then
        local inner = nil
        for k, v in pairs(rv_res) do
            if k == "result" and type(v) == "table" then inner = v end
        end
        res_table = inner or rv_res
    end

    local side_chat_text = ""
    local suggested_target_slot = nil
    local reasoning = ""
    for k, v in pairs(res_table) do
        if k == "side_chat_text" then side_chat_text = tostring(v) end
        if k == "suggested_target_slot" then suggested_target_slot = tonumber(v) end
        if k == "reasoning" then reasoning = tostring(v) end
    end

    -- Defensive: keep suggestion in the living-target list; fall back if not.
    local valid = false
    for _, slot in ipairs(living_target_slots or {}) do
        if tonumber(slot) == suggested_target_slot then valid = true; break end
    end
    if not valid then suggested_target_slot = fallback_slot end

    process.send(state.parent_pid, "night.side_chat.reply", {
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
