-- src/npc/turn_vote.lua
-- D-05 (Phase 6): Vote turn handler — run_vote_turn.
-- Two-stage informed voting non-negotiable: private suspicion update (apply_suspicion_updates)
-- then llm.structured_output returning {vote_target, reasoning, suspicion_updates}.
-- Not random, not bandwagon-by-default. Suspicion persisted to SQL at round end (NPC-08).

local logger    = require("logger"):named("turn_vote")
local time      = require("time")
local sql       = require("sql")
local json      = require("json")
local llm       = require("llm")
local pe        = require("pe")
local prompts   = require("prompts")
local errors    = require("errors")
local suspicion = require("suspicion")
local event_log = require("event_log")

local MODEL      = "claude-haiku-4-5"
local VOTE_CAP_S = "15s"

-- VOTE_SCHEMA per CONTEXT.md D-04 — vote_target is a NAME string, not slot.
local VOTE_SCHEMA = {
    type = "object",
    properties = {
        suspicion_updates = {
            type = "object",
            description = "Delta changes to private suspicion of each named player, in [-20, 20].",
            additionalProperties = { type = "integer", minimum = -20, maximum = 20 },
        },
        reflection_notes = {
            type = "object",
            description = "Short per-player notes (<=60 chars) grounding this round's suspicion.",
            additionalProperties = { type = "string", maxLength = 60 },
        },
        vote_target = {
            type = "string",
            description = "Name of a living non-self player you vote to eliminate. Must be one of the players in the ROSTER. Abstention is not allowed.",
        },
        reasoning = {
            type = "string",
            maxLength = 400,
            description = "One-sentence reason referencing specific discussion content, addressing players by name.",
        },
    },
    required = { "suspicion_updates", "reflection_notes", "vote_target", "reasoning" },
    additionalProperties = false,
}

local function run_vote_turn(state, round)
    prompts.assert_stable_hash(state)
    state.round = round
    local parent_pid = tostring(state.parent_pid)
    local p = prompts.build_vote_prompt(state)

    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.structured_output(VOTE_SCHEMA, p, { model = MODEL })
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

    -- framework/llm wraps structured_output as { result = <schema_table>, ... }
    local res = {}
    if type(rv_res) == "table" then
        local inner = nil
        for k, v in pairs(rv_res) do
            if k == "result" and type(v) == "table" then inner = v end
        end
        if inner then
            res = inner
        else
            res = rv_res
        end
    end

    -- Apply suspicion deltas + persist snapshot (NPC-08).
    local res_suspicion_updates = nil
    local res_reflection_notes = nil
    local res_vote_target = nil
    local res_reasoning = ""
    for k, v in pairs(res) do
        if k == "suspicion_updates" then res_suspicion_updates = v end
        if k == "reflection_notes" then res_reflection_notes = v end
        if k == "vote_target" then res_vote_target = v end
        if k == "reasoning" then res_reasoning = tostring(v) end
    end

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
