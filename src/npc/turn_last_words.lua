-- src/npc/turn_last_words.lua
-- D-05 (Phase 6): Last-words turn handler — run_last_words.
-- Phase 7: migrated from llm direct calls to the wippy/agent runner:step call.
-- "Exactly one in-persona last words on elimination" — Phase 3 success criterion NPC-09.
-- Non-streaming: coroutine-spawned runner:step raced against a 10s deadline.

local logger          = require("logger"):named("turn_last_words")
local time            = require("time")
local sql             = require("sql")
local json            = require("json")
local pe              = require("pe")
local prompt = require("prompt")
local prompts         = require("prompts")
local errors          = require("errors")
local visible_context = require("visible_context")
local event_log       = require("event_log")

-- Phase 7: MODEL constant removed - model is set in agent definition (npc.lua ctx:load_agent).
local LAST_WORDS_CAP_S = "10s"

local function run_last_words(state, round)
    prompts.assert_stable_hash(state)
    -- Phase 7: user-message-only conversation. Agent runner injects system prompt.
    local p = prompt.new()
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
        roster_names = state.roster_names,
        slot = state.slot,
    }, "chat")
    local directive
    if state.role == "mafia" then
        directive = "\n\n===YOU HAVE BEEN ELIMINATED===\nSay one last thing in character (1-2 sentences). You may reveal nothing, taunt, or try to sow doubt. Do NOT explicitly out your partner. Keep it short."
    else
        directive = "\n\n===YOU HAVE BEEN ELIMINATED===\nSay one last thing in character (1-2 sentences). You may accuse someone, plead innocence, or offer a dying clue. Keep it short."
    end
    p:add_user(tail .. directive)

    -- Non-streaming — race a coroutine-spawned runner:step against a 10s cap.
    -- Phase 7 architectural contract pin: state.runner is set in npc.lua process
    -- init and inherited via the state table. If this assert fires, npc.lua init
    -- order is broken or library.lua state inheritance changed — fix at the source.
    assert(state.runner ~= nil, "runner missing — npc.lua init order broken")
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        -- Phase 7 D-12-FALLBACK: retry wrapper around the runner call.
        local res, err = errors.with_retry(state.npc_id, "last_words", function()
            return state.runner:step(p, {})
        end)
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(LAST_WORDS_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })
    if not r.ok or r.channel ~= result_ch then
        errors.persist_error(state.npc_id, "last_words", { type = "TIMEOUT" }, 0)
        return nil, "timeout"
    end
    -- r.channel == result_ch: linter knows r.value is from result_ch's send type
    local rv = r.value
    local rv_err = nil
    local rv_res = nil
    for k, v in pairs(rv) do
        if k == "err" then rv_err = v end
        if k == "res" then rv_res = v end
    end
    if rv_err then
        errors.persist_error(state.npc_id, "last_words", rv_err, 0)
        return nil, rv_err
    end

    -- First-run probe: log the raw result shape so field path is confirmed.
    -- This log is cheap and stays on — if a future framework update
    -- changes the shape, this log catches it immediately.
    local keys = {}
    if type(rv_res) == "table" then
        for k, _ in pairs(rv_res) do table.insert(keys, tostring(k)) end
    end
    logger:info("[npc] last_words raw res", {
        npc = state.npc_id,
        res_type = type(rv_res),
        keys = keys,
    })

    -- Phase 7: agent runner response.result is the generated string directly.
    -- Hoisted out of an `and/or` chain so luals can narrow rv_res through the type guard.
    local text = ""
    if type(rv_res) == "table" and type(rv_res.result) == "string" then
        text = rv_res.result
    end

    -- Non-empty guard preserved: wrong runner contract or empty result silently
    -- returns "" which would break NPC-09 (no last-words). The assert fires
    -- on broken upstream so the regression is caught at first failure.
    assert(#text > 0, string.format(
        "[npc] run_last_words got empty response.result — npc=%s res_keys=%s",
        state.npc_id, table.concat(keys, ",")))
    return text
end

return {
    run_last_words = run_last_words,
}
