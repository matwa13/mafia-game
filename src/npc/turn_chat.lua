-- src/npc/turn_chat.lua
-- D-05 (Phase 6): Day-chat turn handler — run_chat_turn.
-- Phase 7: migrated from llm direct calls to the wippy/agent runner:step call.
-- Two-pass round-robin non-negotiable: every alive NPC speaks an opening then a follow-up.
-- Both turns are mandatory; the defensive DECLINE-strip enforces it (Phase 3.1 polish).
-- Phase 3.1 UX: no chunk streaming - orchestrator publishes typing.started/ended; SPA
-- renders a typing bubble. Full text committed atomically when ready.

local logger    = require("logger"):named("turn_chat")
local time      = require("time")
local sql       = require("sql")
local json      = require("json")
local pe        = require("pe")
local prompts   = require("prompts")
local errors    = require("errors")
local event_log = require("event_log")

-- Phase 7: MODEL constant removed - model is set in agent definition (npc.lua ctx:load_agent).
local CHAT_CAP_S = "22s"    -- streaming-window deadline (preserved for race)

local function run_chat_turn(state, round, is_mandatory)
    prompts.assert_stable_hash(state)
    state.round = round

    local parent_pid = tostring(state.parent_pid)
    local p = prompts.build_chat_prompt(state, is_mandatory)

    -- Blocking generate in a coroutine so the main select loop can still
    -- race a deadline, CANCEL, and abort.turn against the LLM call.
    -- Phase 7 architectural contract pin: state.runner is set in npc.lua process
    -- init and inherited via the state table. If this assert fires, npc.lua init
    -- order is broken or library.lua state inheritance changed — fix at the source,
    -- do NOT add a defensive default here.
    assert(state.runner ~= nil, "runner missing — npc.lua init order broken")
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        -- Phase 7 D-12-FALLBACK: retry wrapper around the runner call.
        -- Blocking (no streaming target) — preserves the typing-indicator UX
        -- (atomic commit on chat.submit).
        local res, err = errors.with_retry(state.npc_id, "chat", function()
            return state.runner:step(p, {})
        end)
        result_ch:send({ res = res, err = err })
    end)

    local deadline = time.after(CHAT_CAP_S)
    local proc_ev = process.events()
    local inbox = process.inbox()

    while true do
        local r = channel.select({
            result_ch:case_receive(),
            deadline:case_receive(),
            proc_ev:case_receive(),
            inbox:case_receive(),
        })

        if not r.ok or r.channel == deadline then
            state.last_llm_error = { type = "TIMEOUT", context = "chat", round = round }
            errors.persist_error(state.npc_id, "chat", { type = "TIMEOUT", message = CHAT_CAP_S }, 0)
            process.send(parent_pid, "chat.decline", {
                from_slot = state.slot, round = round, reason = "timeout",
            })
            return

        elseif r.channel == result_ch then
            local rv = r.value
            local rv_err, rv_res
            if type(rv) == "table" then
                for k, v in pairs(rv) do
                    if k == "err" then rv_err = v end
                    if k == "res" then rv_res = v end
                end
            end
            if rv_err then
                local cls = errors.classify(rv_err)
                state.last_llm_error = { type = cls.reason or "error", context = "chat", round = round }
                errors.persist_error(state.npc_id, "chat", rv_err, 0)
                process.send(parent_pid, "chat.decline", {
                    from_slot = state.slot, round = round,
                    reason = "llm_" .. (cls.reason or "error"),
                })
                pe.publish_event("system", "npc_turn_skipped", "/" .. state.game_id, {
                    npc_id = state.npc_id, slot = state.slot, round = round, reason = "chat_gen_error",
                })
                return
            end
            -- Phase 7: agent runner response.result is already a string.
            local full = (type(rv_res) == "table" and type(rv_res.result) == "string") and rv_res.result or ""
            -- Defensive: detect and strip "DECLINE" / "DECLINED" tokens that the
            -- model may echo from cached context. Both turns are mandatory; DECLINE
            -- is never instructed (see prompts.lua lines 39-58). If the LLM only
            -- emits DECLINE (whole-reply or leading-token forms), treat the turn
            -- as a soft skip — the orchestrator's chat.submit handler tolerates
            -- empty text and the per-speaker cap progresses to the next NPC.
            local trimmed = full:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed:match("^[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]?[%s%p]*$") then
                -- Whole reply is a DECLINE token (e.g. "DECLINE", "DECLINED.", "decline ").
                full = ""
            else
                -- Strip leading "DECLINE because..." preamble.
                full = full:gsub("^%s*[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]?[%s%p]+", "")
                -- Strip trailing "...DECLINE" / "...DECLINED" tail (preserved from prior fix).
                full = full:gsub("[%s%p]+[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]?[%s%p]*$", "")
            end
            process.send(parent_pid, "chat.submit", {
                from_slot = state.slot, round = round,
                text = full, kind = "npc",
            })
            return

        elseif r.channel == proc_ev then
            local event = r.value
            if type(event) == "table" then
                local ekind
                for k, v in pairs(event) do
                    if k == "kind" then ekind = v end
                end
                if ekind == process.event.CANCEL then
                    return
                end
            end

        elseif r.channel == inbox then
            local msg = r.value
            if type(msg) == "table" and msg.topic then
                local tp = msg:topic()
                if tp == "abort.turn" then
                    process.send(parent_pid, "chat.decline", {
                        from_slot = state.slot, round = round, reason = "aborted_by_orchestrator",
                    })
                    return
                end
            end
            -- Other inbox topics during the LLM call are ignored; the
            -- orchestrator doesn't send day.turn/vote.prompt mid-turn
            -- under the current FSM.
        end
    end
end

return {
    run_chat_turn = run_chat_turn,
}
