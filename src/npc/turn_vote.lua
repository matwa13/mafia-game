-- src/npc/turn_vote.lua
-- D-05 (Phase 6): Vote turn handler — run_vote_turn.
-- Phase 7: migrated from wippy/llm structured output to agent runner:step (Approach A schema-as-tool).
-- Schema lives in src/npc/agents/_index.yaml (vote_tool entry); runner forces tool_call.
-- Two-stage informed voting non-negotiable: private suspicion update (apply_suspicion_updates)
-- then runner:step returns suspicion_updates + reflection_notes + vote_target + reasoning via tool args.
-- Not random, not bandwagon-by-default. Suspicion persisted to SQL at round end (NPC-08).

local logger    = require("logger"):named("turn_vote")
local time      = require("time")
local sql       = require("sql")
local json      = require("json")
local pe        = require("pe")
local prompts   = require("prompts")
local errors    = require("errors")
local suspicion = require("suspicion")
local event_log = require("event_log")

-- Phase 7: MODEL constant removed - model is set in agent definition (npc.lua ctx:load_agent).
local VOTE_CAP_S = "15s"

-- Phase 7: VOTE_SCHEMA moved to src/npc/agents/_index.yaml (vote_tool meta.input_schema).
-- The runner forces a tool_call; structured args arrive at response.tool_calls[1].arguments.

local function run_vote_turn(state, round)
    prompts.assert_stable_hash(state)
    state.round = round
    local parent_pid = tostring(state.parent_pid)
    local p = prompts.build_vote_prompt(state)

    -- Phase 7 architectural contract pin: state.runner is set in npc.lua process
    -- init and inherited via the state table. If this assert fires, npc.lua init
    -- order is broken or library.lua state inheritance changed — fix at the source,
    -- do NOT add a defensive default here. Plan 04 confirmed this contract holds
    -- for turn_chat / turn_last_words; turn_vote uses state.tool_runner
    -- (the second per-NPC runner with schema-as-tool entries registered).
    assert(state.tool_runner ~= nil, "tool_runner missing — npc.lua init order broken")
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        -- Phase 7 D-12-FALLBACK + Approach A: runner:step with named tool_call
        -- forces the LLM to invoke cast_vote (the llm_alias of vote_tool —
        -- registered in src/npc/agents/_index.yaml). Structured args are
        -- validated against meta.input_schema and surfaced via
        -- response.tool_calls[1].arguments.
        local res, err = errors.with_retry(state.npc_id, "vote", function()
            return state.tool_runner:step(p, { tool_call = "cast_vote" })
        end)
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        state.last_llm_error = { type = "TIMEOUT", context = "vote", round = round }
        errors.persist_error(state.npc_id, "vote", { type = "TIMEOUT", message = "15s cap" }, 0)
        process.send(parent_pid, "vote.cast", {
            from_slot = state.slot, vote_for_slot = nil,
            reasoning = "llm_timeout", round = round,
        })
        return
    end
    -- r.channel == result_ch: r.value is from result_ch
    local rv = r.value
    local rv_err = nil
    local rv_res = nil
    for k, v in pairs(rv) do
        if k == "err" then rv_err = v end
        if k == "res" then rv_res = v end
    end
    if rv_err then
        state.last_llm_error = { type = "llm_error", context = "vote", round = round }
        errors.persist_error(state.npc_id, "vote", rv_err, 0)
        process.send(parent_pid, "vote.cast", {
            from_slot = state.slot, vote_for_slot = nil,
            reasoning = "llm_error", round = round,
        })
        return
    end

    -- Phase 7: agent runner with tool_call="any" surfaces structured args at
    -- response.tool_calls[1].arguments (already a Lua table — schema-validated).
    local res = {}
    if type(rv_res) == "table" and type(rv_res.tool_calls) == "table"
       and type(rv_res.tool_calls[1]) == "table"
       and type(rv_res.tool_calls[1].arguments) == "table" then
        res = rv_res.tool_calls[1].arguments
    end

    -- Apply suspicion deltas + persist snapshot (NPC-08).
    local res_suspicion_updates = res.suspicion_updates
    local res_reflection_notes  = res.reflection_notes
    local res_vote_target       = res.vote_target
    local res_reasoning         = tostring(res.reasoning or "")

    suspicion.apply_suspicion_updates(state, res_suspicion_updates, res_reflection_notes)
    local ok, perr = suspicion.persist_suspicion_snapshot(state.npc_id, state.game_id, round, state.suspicion)
    if not ok then
        logger:warn("[npc] suspicion snapshot persist failed", {
            npc = state.npc_id, round = round, err = tostring(perr),
        })
    end

    -- Resolve vote_target NAME -> slot integer (orchestrator expects vote_for_slot).
    local vote_for_slot = nil
    if type(res_vote_target) == "string" and res_vote_target ~= "" then
        vote_for_slot = state.name_to_slot[res_vote_target]
        if not vote_for_slot then
            logger:warn("[npc] vote_target name not in roster", {
                npc = state.npc_id, target = res_vote_target,
            })
            -- Fall through as abstain rather than bandwagon-recover.
        end
    end

    -- D-DP-06: capture last_vote for dev telemetry.
    state.last_vote = {
        round = round,
        target_slot = vote_for_slot,
        justification = res_reasoning,
    }

    process.send(parent_pid, "vote.cast", {
        from_slot = state.slot,
        vote_for_slot = vote_for_slot,
        reasoning = res_reasoning,
        round = round,
    })
end

return {
    run_vote_turn = run_vote_turn,
}
