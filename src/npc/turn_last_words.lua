-- src/npc/turn_last_words.lua
-- D-05 (Phase 6): Last-words turn handler — run_last_words.
-- "Exactly one in-persona last words on elimination" — Phase 3 success criterion NPC-09.
-- Non-streaming: coroutine-spawned llm.generate raced against a 10s deadline.
-- errors.extract_generate_text (shared with turn_chat) unwraps the LLM result shape.

local logger          = require("logger"):named("turn_last_words")
local time            = require("time")
local sql             = require("sql")
local json            = require("json")
local llm             = require("llm")
local pe              = require("pe")
local prompt          = require("prompt")
local prompts         = require("prompts")
local errors          = require("errors")
local visible_context = require("visible_context")
local event_log       = require("event_log")

local MODEL            = "claude-haiku-4-5"
local LAST_WORDS_CAP_S = "10s"

local function run_last_words(state, round)
    prompts.assert_stable_hash(state)
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
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

    -- Non-streaming — race a coroutine-spawned generate against a 10s cap.
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.generate(p, { model = MODEL })
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
    -- This log is cheap and stays on — if a future Wippy/framework-llm update
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

    -- Extract text via errors.extract_generate_text (shared with turn_chat).
    local text = errors.extract_generate_text(rv_res)
    if type(text) ~= "string" then text = tostring(text) end

    -- Non-empty guard: wrong field path silently returns "" which breaks NPC-09.
    -- If this assert fires on first run, inspect the logged `keys` above and
    -- pick the correct field.
    assert(#text > 0, string.format(
        "[npc] run_last_words extracted empty text — wrong field path? npc=%s res_keys=%s",
        state.npc_id, table.concat(keys, ",")))
    return text
end

return {
    run_last_words = run_last_words,
}
