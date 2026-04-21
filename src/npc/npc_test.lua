-- src/npc/npc_test.lua
-- The single Phase-1 NPC process. Exercises every structural primitive:
--   * supervised process.lua + name registration (npc:test)
--   * role-aware event subscriptions (D-10)
--   * channel.select main loop (inbox + events + per-scope channels)
--   * streaming chat with cooperative cancel (D-01, D-03, D-05)
--   * structured-output vote with hard timeout (D-02, D-06) via coroutine.spawn
--   * error classification + retry/backoff + SQL persistence (D-04, D-07, D-08)
--   * persona SHA-256 tripwire on every turn (D-15)
--   * visible_context-only prompt building (D-11, D-12)
--
-- Plan 05's test_driver exercises each directive via inbox reply_to acks.

local logger          = require("logger"):named("npc_test")
local events          = require("events")
local time            = require("time")
local sql             = require("sql")
local json            = require("json")
local llm             = require("llm")
local prompt          = require("prompt")
local hash            = require("hash")
local pe              = require("app.lib:events")
local persona         = require("app.npc:persona")
local visible_context = require("app.npc:visible_context")

-- Section B: constants -----------------------------------------------------
local NPC_ID      = "npc:test"       -- runtime process-id (colons allowed)
local MODEL       = "claude-haiku-4-5"
local CHAT_CAP_S  = "20s"            -- D-03
local VOTE_CAP_S  = "15s"            -- D-03
local MAX_RETRIES = 2                -- D-04
local BACKOFFS    = { "1s", "3s" }   -- D-04

local VOTE_SCHEMA = {
    type = "object",
    properties = {
        vote_target = { type = { "integer", "null" } },
        reasoning   = { type = "string", maxLength = 400 },
    },
    required = { "vote_target", "reasoning" },
    additionalProperties = false,
}

-- Section C: error helpers (D-07 SQL persistence) --------------------------

--- Classify an LLM error-return. Retryable for RATE_LIMIT/SERVER_ERROR/
--- TIMEOUT/NETWORK_ERROR; everything else is a one-shot fallback.
local function classify(err)
    if not err then return { retryable = false, reason = "ok" } end
    local t = err.type
    if t == "RATE_LIMIT" or t == "SERVER_ERROR"
        or t == "TIMEOUT" or t == "NETWORK_ERROR" then
        return { retryable = true, reason = tostring(t):lower() }
    end
    return { retryable = false, reason = tostring(t or "unknown"):lower() }
end

--- Persist one error row to app:db.errors. D-07 mandates every retry attempt
--- plus the final fallback each write a row. Acquire/release per-write
--- (Phase 0 lesson — no imports: on process.lua entries).
local function persist_error(npc_id, call_type, err, retry_count)
    logger:warn(string.format("[npc_test] LLM error call=%s retry=%d type=%s",
        call_type, retry_count, tostring(err and err.type)))
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        logger:error("sql.get failed in persist_error", { err = tostring(db_err) })
        return
    end
    -- err.message is redacted by framework/llm. No headers are persisted.
    db:execute(
        "INSERT INTO errors (ts, npc_id, call_type, http_code, message, retry_count) "
        .. "VALUES (?, ?, ?, ?, ?, ?)",
        os.time(), npc_id, call_type,
        tostring((err and err.http_code) or ""),
        tostring((err and err.message) or ""),
        retry_count
    )
    db:release()
end

-- Section D: retry-with-backoff helper -------------------------------------

--- with_retry(call_type, fn) — fn() returns (value, err). Retries up to
--- MAX_RETRIES on retryable errors. Every attempt (including the final
--- failure) writes a row to the errors table. Returns (value, nil) on
--- success, or (nil, last_err) on final failure.
local function with_retry(call_type, fn)
    local attempt = 0
    while true do
        local value, err = fn()
        if not err then return value, nil end
        persist_error(NPC_ID, call_type, err, attempt)
        local c = classify(err)
        if not c.retryable or attempt >= MAX_RETRIES then
            return nil, err
        end
        local backoff = BACKOFFS[attempt + 1] or "3s"
        if err.retry_after and err.retry_after > 0 then
            backoff = tostring(err.retry_after) .. "s"
        end
        time.sleep(backoff)
        attempt = attempt + 1
    end
end

-- Section E: streaming chat call (D-01, D-03, D-05) ------------------------

--- call_chat_stream(prompt_obj) — fire llm.generate with streaming config,
--- accumulate chunks from process.listen(CHUNK_TOPIC) inside an inner
--- channel.select racing chunk delivery vs 20s deadline vs CANCEL.
--- Returns (text, nil) on success, (nil, err_record) on any failure.
--- process.unlisten is called on EVERY exit path.
local function call_chat_stream(prompt_obj)
    local CHUNK_TOPIC = "llm.chat.chunk:" .. tostring(process.pid())
    local chunk_ch = process.listen(CHUNK_TOPIC)
    local deadline = time.after(CHAT_CAP_S)

    local _, gen_err = llm.generate(prompt_obj, {
        model  = MODEL,
        stream = { reply_to = process.pid(), topic = CHUNK_TOPIC },
    })
    if gen_err then
        process.unlisten(chunk_ch)
        return nil, gen_err
    end

    local buf = {}
    while true do
        local r = channel.select({
            chunk_ch:case_receive(),
            deadline:case_receive(),
            process.events():case_receive(),
        })
        if not r.ok or r.channel == deadline then
            process.unlisten(chunk_ch)
            return nil, { type = "TIMEOUT", message = "chat " .. CHAT_CAP_S .. " cap" }
        end
        if r.channel == process.events() and r.value
            and r.value.kind == process.event.CANCEL then
            process.unlisten(chunk_ch)
            return nil, { type = "CANCELLED" }
        end
        local chunk = r.value:payload():data()
        if chunk.type == "chunk" then
            table.insert(buf, chunk.content or "")
        elseif chunk.type == "error" then
            process.unlisten(chunk_ch)
            return nil, chunk
        elseif chunk.type == "done" then
            process.unlisten(chunk_ch)
            return table.concat(buf), nil
        end
        -- "thinking" / "tool_call" ignored in Phase 1
    end
end

-- Section F: structured vote call via coroutine.spawn (WARNING 4 lock-in) --

--- call_vote_structured(prompt_obj) — llm.structured_output is synchronous
--- (no stream/async option). The idiomatic Wippy in-process concurrency
--- primitive is coroutine.spawn — schedule the blocking call, race its
--- result channel against a 15s deadline (D-02, D-03).
local function call_vote_structured(prompt_obj)
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.structured_output(VOTE_SCHEMA, prompt_obj, { model = MODEL })
        result_ch:send({ res = res, err = err })
    end)

    local r = channel.select({
        result_ch:case_receive(),
        time.after(VOTE_CAP_S):case_receive(),
    })
    if not r.ok or r.channel ~= result_ch then
        return nil, { type = "TIMEOUT", message = "vote " .. VOTE_CAP_S .. " cap" }
    end
    return r.value.res, r.value.err
end

-- Section G: prompt building (D-13, D-14, D-16) ----------------------------

local function build_chat_prompt(state)
    local p = prompt.new()
    p:add_system(state.stable_block)    -- BYTE-IDENTICAL every turn (D-13)
    p:add_cache_marker()                -- Anthropic ephemeral breakpoint
    local dyn = visible_context(NPC_ID, state) ..
        "\n\nIt is your turn to speak in the day discussion. Respond in character, one short message."
    p:add_user(dyn)
    return p
end

--- render_suspicion(suspicion) — stringify the private suspicion table for
--- injection into the VOTE prompt. D-16: NEVER called from build_chat_prompt.
local function render_suspicion(suspicion)
    if not suspicion or next(suspicion) == nil then
        return "(no suspicion data yet)"
    end
    local parts = { "Current suspicion scores:" }
    for slot, score in pairs(suspicion) do
        table.insert(parts, string.format("  slot %s: %.2f", tostring(slot), score))
    end
    return table.concat(parts, "\n")
end

local function build_vote_prompt(state)
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
    local dyn = visible_context(NPC_ID, state) ..
        "\n\n" .. render_suspicion(state.suspicion) ..
        "\n\nCast your vote. Output JSON matching the required schema. If unsure, vote for the highest-suspicion slot."
    p:add_user(dyn)
    return p
end

-- Section H: D-15 persona-hash tripwire ------------------------------------

--- assert_stable_hash(state) — re-compute SHA-256 over the bytes about to
--- be sent and assert equal to the boot-time hash. Panic on mismatch —
--- the supervisor catches the crash and restarts, at which point the
--- recomputed hash matches again (assuming the mutation was transient).
--- This is one of only TWO intentional panic sites (the other is D-11
--- in visible_context).
local function assert_stable_hash(state)
    local now_bytes = tostring(persona.render_stable_block(persona.FIXTURE, state.role))
    local now_hash = hash.sha256(now_bytes)
    assert(now_hash == state.stable_hash,
        string.format("PERSONA DRIFT: npc=%s boot_hash=%s now_hash=%s",
            NPC_ID, state.stable_hash, now_hash))
end

-- Section I: directive handlers --------------------------------------------

--- forced_error_fn(payload) — BLOCKER 2 / force_error debug hook.
--- Returns a closure suitable as the `fn` argument to with_retry. The
--- closure returns (nil, err_record) as a TUPLE VALUE — D-08 preserved.
--- Retry, backoff, persist, fallback all run as normal.
local function forced_error_fn(payload)
    return function()
        return nil, {
            type      = payload.error_type or "RATE_LIMIT",
            http_code = 429,
            message   = "forced error (debug)",
        }
    end
end

local function handle_speak(state, payload)
    payload = payload or {}
    assert_stable_hash(state)
    local p = build_chat_prompt(state)

    local force_error, reply_to, error_type
    for k, v in pairs(payload) do
        if k == "force_error" then force_error = v end
        if k == "reply_to"    then reply_to    = v end
        if k == "error_type"  then error_type  = v end
    end

    local call_fn
    if force_error == true then
        call_fn = forced_error_fn({ error_type = error_type })
    else
        call_fn = function() return call_chat_stream(p) end
    end

    local text, err = with_retry("chat", call_fn)
    if err or not text or text == "" then
        local reason = classify(err).reason
        pe.publish_event("system", "npc_turn_skipped",
            "/game/test/npc/" .. NPC_ID, { npc_id = NPC_ID, reason = reason })
        if type(reply_to) == "string" then
            process.send(reply_to, "npc_turn_skipped_ack",
                { npc_id = NPC_ID, reason = reason })
        end
        return
    end
    pe.publish_event("public", "npc.message",
        "/game/test/round/1", { npc_id = NPC_ID, text = text })
    if type(reply_to) == "string" then
        process.send(reply_to, "npc_message_done",
            { npc_id = NPC_ID, text = text })
    end
end

local function handle_vote(state, payload)
    payload = payload or {}
    assert_stable_hash(state)
    local p = build_vote_prompt(state)

    local force_error, reply_to, error_type
    for k, v in pairs(payload) do
        if k == "force_error" then force_error = v end
        if k == "reply_to"    then reply_to    = v end
        if k == "error_type"  then error_type  = v end
    end

    local call_fn
    if force_error == true then
        call_fn = forced_error_fn({ error_type = error_type })
    else
        call_fn = function() return call_vote_structured(p) end
    end

    local result, err = with_retry("vote", call_fn)
    local vote_target, reasoning = nil, nil
    if type(result) == "table" then
        for k, v in pairs(result) do
            if k == "vote_target" then vote_target = v end
            if k == "reasoning"   then reasoning   = v end
        end
    end
    if err or vote_target == nil then
        local reason = classify(err).reason
        pe.publish_event("system", "npc.vote",
            "/game/test/round/1",
            { npc_id = NPC_ID, vote_target = nil, reason = "llm_error" })
        if type(reply_to) == "string" then
            process.send(reply_to, "vote_done",
                { npc_id = NPC_ID, vote_target = nil, reason = reason })
        end
        return
    end
    pe.publish_event("system", "npc.vote",
        "/game/test/round/1",
        { npc_id = NPC_ID, vote_target = vote_target, reasoning = reasoning })
    if type(reply_to) == "string" then
        process.send(reply_to, "vote_done",
            { npc_id = NPC_ID, vote_target = vote_target, reasoning = reasoning })
    end
end

-- Section J: event ingestion (D-10 belt + D-11 suspenders on render) -------

--- unpack_event(evt) — extract (kind, data) from a subscription-channel event
--- via pairs() to bypass the linter's process.Event narrowing (the linter
--- unions process.Event into r.value on channels that share a select with
--- process.events(); process.Event has .kind but not .data).
local function unpack_event(evt)
    if type(evt) ~= "table" then return nil, nil end
    local kind, data
    for k, v in pairs(evt) do
        if k == "kind" then kind = v end
        if k == "data" then data = v end
    end
    return kind, data
end

--- ingest_event(state, kind, data) — append an incoming subscription-channel
--- event to the in-memory event_log if its claimed scope is allowed for
--- this NPC's role. Panic deferred to visible_context (D-11); here we
--- silently drop to keep the log clean.
local function ingest_event(state, kind, data)
    local claimed_scope = data and data.scope
    if not pe.scope_allowed(state.role, claimed_scope) then
        logger:warn("[npc_test] dropped event at ingest",
            { role = state.role, claimed_scope = tostring(claimed_scope) })
        return
    end
    table.insert(state.event_log, {
        scope = claimed_scope,
        kind  = kind,
        text  = (data and data.text) or "",
        ts    = os.time(),
    })
end

-- Section K: run(args) main entry -----------------------------------------

local function run(args)
    local inbox = process.inbox()
    local proc_ev = process.events()

    local role = (args and args.role) or "villager"
    local reg_ok, reg_err = process.registry.register("npc:test")
    if not reg_ok then
        logger:warn("[npc_test] registry.register failed", { error = tostring(reg_err) })
    end
    logger:info("[npc_test] started", { role = role })

    -- D-13/D-15: build the stable block ONCE at boot, hash it, hold both.
    local stable_block = tostring(persona.render_stable_block(persona.FIXTURE, role))
    local stable_hash  = hash.sha256(stable_block)
    logger:info("[npc_test] persona stable-block hash", {
        hash  = stable_hash,
        bytes = #stable_block,
    })
    -- Research Open Q#2: <2000 bytes is well under the 4096-token Anthropic
    -- cache threshold; the cache marker becomes a no-op. D-15 tripwire is
    -- the authoritative byte-identity guarantee regardless.
    if #stable_block < 2000 then
        logger:info("[npc_test] stable-block likely below 4096 token cache threshold — cache breakpoint is a documented no-op; D-15 SHA-256 tripwire remains authoritative")
    end

    local state = {
        role         = role,
        event_log    = {},
        suspicion    = {},
        stable_block = stable_block,
        stable_hash  = stable_hash,
    }

    -- D-10 role-aware subscriptions.
    local public_sub = events.subscribe("mafia.public", "*")
    local system_sub = events.subscribe("mafia.system:" .. NPC_ID, "*")
    local mafia_sub  = nil
    if role == "mafia" then
        mafia_sub = events.subscribe("mafia.mafia", "*")
    end
    local public_ch = public_sub and public_sub:channel() or nil
    local system_ch = system_sub and system_sub:channel() or nil
    local mafia_ch  = mafia_sub  and mafia_sub:channel()  or nil

    while true do
        local cases = {
            inbox:case_receive(),
            proc_ev:case_receive(),
        }
        if public_ch then table.insert(cases, public_ch:case_receive()) end
        if system_ch then table.insert(cases, system_ch:case_receive()) end
        if mafia_ch  then table.insert(cases, mafia_ch:case_receive())  end

        local r = channel.select(cases)
        if not r.ok then return end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local payload = {}
            local raw_payload = msg:payload():data()
            if type(raw_payload) == "table" then
                for k, v in pairs(raw_payload) do payload[k] = v end
            end
            if topic == "ping" then
                -- V-01-01 reachability: immediate pong, no LLM, no SHA check.
                local rt = payload.reply_to
                if type(rt) == "string" then
                    process.send(rt, "pong", { npc_id = NPC_ID })
                end
            elseif topic == "speak" then
                handle_speak(state, payload)
            elseif topic == "vote" then
                handle_vote(state, payload)
            elseif topic == "export_event_log" then
                -- V-01-07 villager-no-mafia: return shallow copy of event log.
                local rt = payload.reply_to
                local copy = {}
                for i, e in ipairs(state.event_log) do copy[i] = e end
                if type(rt) == "string" then
                    process.send(rt, "event_log", { events = copy })
                end
            elseif topic == "mutate_persona" then
                -- V-01-09 debug: mutate the fixture in place so the next
                -- assert_stable_hash call panics (observable as supervisor restart).
                persona.FIXTURE.name = "mutated-" .. tostring(os.time())
                logger:warn("[npc_test] persona MUTATED for tripwire test")
            elseif topic == "inject_event" then
                -- V-01-08 debug: bypass ingest_event + scope_allowed and drop
                -- a forged event into the log. visible_context will panic on
                -- the next speak/vote.
                table.insert(state.event_log, payload)
            end
        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                return
            end
        elseif r.channel == public_ch then
            local kind, data = unpack_event(r.value)
            ingest_event(state, kind, data)
        elseif r.channel == system_ch then
            local kind, data = unpack_event(r.value)
            ingest_event(state, kind, data)
        elseif r.channel == mafia_ch then
            local kind, data = unpack_event(r.value)
            ingest_event(state, kind, data)
        end
    end
end

return { run = run }
