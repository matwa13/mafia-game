-- src/npc/turn_night_pick.lua
-- D-05 (Phase 6): Night-pick turn handler — run_night_pick.
-- Phase 7: migrated from wippy/llm structured output to agent runner:step (Approach A schema-as-tool).
-- Schema lives in src/npc/agents/_index.yaml (night_pick_tool entry).
-- LOOP-02 (Mafia-picks branch): Mafia NPC's structured night-pick. Higher confidence
-- wins on tie-break (orchestrator-side, Plan 04). target_slot constrained to
-- living non-Mafia slot list passed in the night.pick request payload.
-- Persona drift tripwire (assert_stable_hash) fires first.

local logger    = require("logger"):named("turn_night_pick")
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

-- Phase 7: NIGHT_PICK_SCHEMA moved to src/npc/agents/_index.yaml (night_pick_tool meta.input_schema).

local function run_night_pick(state, raw)
    prompts.assert_stable_hash(state)
    state.round = (raw.round and tonumber(raw.round)) or state.round or 0
    local round = state.round
    local parent_pid = tostring(state.parent_pid)

    -- Extract living_target_slots + living_target_names from raw payload.
    local living_target_slots = {}
    local living_target_names = {}
    for k, v in pairs(raw) do
        if k == "living_target_slots" then living_target_slots = v end
        if k == "living_target_names" then living_target_names = v end
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
        roster = state.roster or {},
        suspicion = state.suspicion,
        roster_names = state.roster_names,
        slot = state.slot,
    }, "chat")
    -- D-DP-06: capture last dynamic tail for dev telemetry.
    state.last_dynamic_tail = tail
    local names_str = table.concat(living_target_names or {}, ", ")
    local slot_strs = {}
    for _, x in ipairs(living_target_slots or {}) do
        slot_strs[#slot_strs + 1] = tostring(x)
    end
    local slots_str = table.concat(slot_strs, ", ")
    local directive = string.format(
        "\n\n===NIGHT KILL===\nYou are Mafia. It is Night %d. Living non-Mafia targets: %s (slots: %s)\n"
        .. "Pick ONE target slot to eliminate. Give your confidence 0-100. One sentence reasoning.",
        round, names_str, slots_str)
    p:add_user(tail .. directive)

    assert(state.tool_runner ~= nil, "tool_runner missing — npc.lua init order broken")
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        -- Phase 7 D-12-FALLBACK + Approach A: named tool_call forces
        -- pick_night_target (llm_alias of night_pick_tool). Uses tool_runner
        -- (per-NPC second runner with the three schema-as-tool entries).
        local res, err = errors.with_retry(state.npc_id, "night_pick", function()
            return state.tool_runner:step(p, { tool_call = "pick_night_target" })
        end)
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        state.last_llm_error = { type = "TIMEOUT", context = "night_pick", round = round }
        errors.persist_error(state.npc_id, "night_pick", { type = "TIMEOUT", message = tostring(VOTE_CAP_S) }, 0)
        process.send(parent_pid, "night.pick.response", {
            from_slot = state.slot,
            target_slot = fallback_slot,
            reasoning = "llm_timeout",
            confidence = 0,
            round = round,
        })
        return
    end

    -- Unwrap result (same pattern as run_vote_turn's pairs() walk).
    local rv = r.value
    local rv_err, rv_res = nil, nil
    for k, v in pairs(rv) do
        if k == "err" then rv_err = v end
        if k == "res" then rv_res = v end
    end
    if rv_err then
        state.last_llm_error = { type = "llm_error", context = "night_pick", round = round }
        errors.persist_error(state.npc_id, "night_pick", rv_err, 0)
        process.send(parent_pid, "night.pick.response", {
            from_slot = state.slot,
            target_slot = fallback_slot,
            reasoning = "llm_error",
            confidence = 0,
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

    local target_slot = res_table.target_slot and tonumber(res_table.target_slot) or nil
    local reasoning   = tostring(res_table.reasoning or "")
    local confidence  = tonumber(res_table.confidence) or 0

    -- Defensive: if LLM returned an out-of-list slot, fall back to the first
    -- living non-Mafia. Same approach as run_vote_turn name-to-slot resolution.
    local valid = false
    for _, slot in ipairs(living_target_slots or {}) do
        if tonumber(slot) == target_slot then valid = true; break end
    end
    if not valid then
        logger:warn("[npc] night_pick target out of range; falling back",
            { npc = state.npc_id, target_slot = tostring(target_slot) })
        target_slot = fallback_slot
        reasoning = (reasoning ~= "" and reasoning or "out_of_range_fallback")
    end

    -- D-DP-06: capture last_pick for dev telemetry.
    state.last_pick = {
        round = round,
        target_slot = target_slot,
        reasoning = reasoning,
        confidence = confidence,
    }

    process.send(parent_pid, "night.pick.response", {
        from_slot = state.slot,
        target_slot = target_slot,
        reasoning = reasoning,
        confidence = confidence,
        round = round,
    })
end

return {
    run_night_pick = run_night_pick,
}
