-- src/npc/npc.lua — Phase 3 real-LLM NPC.
-- Template: src/npc/npc_test.lua (Phase 1) + parameterized persona per
-- CONTEXT.md D-01..D-04 + SHA256 tripwire (Phase 1 D-15 inherited).
-- Spawned dynamically by orchestrator (not auto_start). Name-registers
-- as "npc:<game_id>:<slot>" before subscribing/ready to avoid missed events.

local logger          = require("logger"):named("npc")
local events          = require("events")
local time            = require("time")
local sql             = require("sql")
local json            = require("json")
local llm             = require("llm")
local prompt          = require("prompt")
local hash            = require("hash")
local pe              = require("pe")
local persona         = require("persona")
local visible_context = require("visible_context")
local channel         = require("channel")

local MODEL            = "claude-haiku-4-5"
local CHAT_CAP_S       = "22s"    -- streaming window
local VOTE_CAP_S       = "15s"
local LAST_WORDS_CAP_S = "10s"
local MAX_RETRIES      = 2
local BACKOFFS         = { "1s", "3s" }

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

-- LOOP-02 (Villager-auto): Mafia NPC's structured night-pick. Higher confidence
-- wins on tie-break (orchestrator-side, Plan 04). target_slot is constrained to
-- the living non-Mafia slot list passed in the night.pick request payload.
local NIGHT_PICK_SCHEMA = {
    type = "object",
    properties = {
        target_slot = {
            type = "integer",
            description = "Slot number of a living non-Mafia player to eliminate. Must be in the living_target_slots list.",
        },
        reasoning = {
            type = "string",
            maxLength = 300,
            description = "One sentence explaining why this target.",
        },
        confidence = {
            type = "integer",
            minimum = 0,
            maximum = 100,
            description = "How confident you are in this pick, 0-100.",
        },
    },
    required = { "target_slot", "reasoning", "confidence" },
    additionalProperties = false,
}

-- Section C: error helpers (D-07 SQL persistence) ---------------------------

--- Classify an LLM error. Retryable for RATE_LIMIT/SERVER_ERROR/TIMEOUT/
--- NETWORK_ERROR; everything else is a one-shot fallback. Accepts both
--- table errors and string errors (npc_test.lua:52-68 verbatim pattern).
local function classify(err)
    if not err then return { retryable = false, reason = "ok" } end
    local err_str = tostring(err)
    local s = err_str:lower()
    if s:find("rate_limit") then return { retryable = true, reason = "rate_limit" } end
    if s:find("server_error") then return { retryable = true, reason = "server_error" } end
    if s:find("timeout") then return { retryable = true, reason = "timeout" } end
    if s:find("network") then return { retryable = true, reason = "network_error" } end
    if type(err) == "table" then
        local t = nil
        for k, v in pairs(err) do
            if k == "type" then t = v end
        end
        if t == "RATE_LIMIT" or t == "SERVER_ERROR"
            or t == "TIMEOUT" or t == "NETWORK_ERROR" then
            return { retryable = true, reason = tostring(t):lower() }
        end
        return { retryable = false, reason = tostring(t or "unknown"):lower() }
    end
    return { retryable = false, reason = "string_error" }
end

--- Persist one error row to app:db.errors. D-07 mandates every retry attempt
--- plus the final fallback each write a row. Acquire/release per-write.
local function persist_error(npc_id, call_type, err, retry_count)
    local err_type, err_http, err_msg
    if type(err) == "string" then
        err_type, err_http, err_msg = "string", "", err
    elseif type(err) == "table" then
        err_type = tostring(err.type or "")
        err_http = tostring(err.http_code or "")
        err_msg  = tostring(err.message or "")
    else
        err_type, err_http, err_msg = tostring(err), "", ""
    end
    logger:warn(string.format("[npc] LLM error call=%s retry=%d type=%s msg=%s",
        call_type, retry_count, err_type, err_msg))
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        logger:error("[npc] sql.get failed in persist_error", { err = tostring(db_err) })
        return
    end
    db:execute(
        "INSERT INTO errors (ts, npc_id, call_type, http_code, message, retry_count) "
        .. "VALUES (?, ?, ?, ?, ?, ?)",
        { os.time(), npc_id, call_type, err_http, err_msg, retry_count }
    )
    db:release()
end

--- with_retry(npc_id, call_type, fn) — fn() returns (value, err). Retries up to
--- MAX_RETRIES on retryable errors. Every attempt writes to errors table.
local function with_retry(npc_id, call_type, fn)
    local attempt = 0
    while true do
        local value, err = fn()
        if not err then return value, nil end
        persist_error(npc_id, call_type, err, attempt)
        local c = classify(err)
        if not c.retryable or attempt >= MAX_RETRIES then
            return nil, err
        end
        local backoff = BACKOFFS[attempt + 1] or "3s"
        if type(err) == "table" and err.retry_after and err.retry_after > 0 then
            backoff = tostring(err.retry_after) .. "s"
        end
        time.sleep(backoff)
        attempt = attempt + 1
    end
end

-- Section D: suspicion persistence helpers ----------------------------------

local function rehydrate_suspicion(npc_id, game_id)
    local db, err = sql.get("app:db")
    if err then
        logger:warn("[npc] sql.get failed on rehydrate", { npc = npc_id, err = tostring(err) })
        return {}
    end
    local rows = db:query(
        "SELECT snapshot_json FROM suspicion_snapshots "
        .. "WHERE game_id = ? AND npc_id = ? "
        .. "ORDER BY round DESC LIMIT 1",
        { game_id, npc_id }
    )
    db:release()
    if rows and rows[1] then
        local snap_json = nil
        for k, v in pairs(rows[1]) do
            if k == "snapshot_json" then snap_json = v end
        end
        if snap_json then
            local decoded, derr = json.decode(tostring(snap_json))
            if decoded then return decoded end
            logger:warn("[npc] snapshot_json decode failed", { npc = npc_id, err = tostring(derr) })
        end
    end
    return {}
end

local function persist_suspicion_snapshot(npc_id, game_id, round, suspicion)
    local db, err = sql.get("app:db")
    if err then return nil, err end
    local json_blob, jerr = json.encode(suspicion or {})
    if jerr then db:release(); return nil, jerr end
    -- Migration 0003 added npc_id + snapshot_json; about_slot + value stay NOT NULL
    -- (0001 schema) so write placeholder 0 / 0.0 for legacy columns.
    local _, exec_err = db:execute(
        "INSERT INTO suspicion_snapshots "
        .. "(game_id, round, slot, about_slot, value, created_at, npc_id, snapshot_json) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        { game_id, round, 0, 0, 0.0, time.now():unix(), npc_id, json_blob }
    )
    db:release()
    if exec_err then return nil, exec_err end
    return true
end

-- Section E: SHA256 persona-hash tripwire -----------------------------------

--- assert_stable_hash(state) — re-compute SHA-256 over the persona block and
--- assert equal to the boot-time hash. Panic on mismatch (D-15 Phase 1 inherited).
local function assert_stable_hash(state)
    local now_bytes = tostring(persona.render_stable_block(state.persona_args))
    local now_hash = hash.sha256(now_bytes)
    assert(now_hash == state.stable_hash,
        string.format("PERSONA DRIFT: npc=%s boot_hash=%s now_hash=%s",
            state.npc_id, state.stable_hash, now_hash))
end

-- Section F: prompt building ------------------------------------------------

local function build_chat_prompt(state, is_mandatory)
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
    -- Phase 3.1: both turns are mandatory. The 2nd turn is a short reactive
    -- follow-up, not an optional skip. This eliminates the DECLINE token
    -- entirely — the LLM has no reason to emit it because it's not in the
    -- prompt anymore.
    local directive
    if is_mandatory then
        directive = "\n\n===SPEAK NOW — OPENING===\nIt's your turn to open. In 1-2 short sentences (max ~40 words), share your read on the day so far. Address other players by name when you accuse, defend, or question. Do NOT write paragraphs."
    else
        directive = "\n\n===SPEAK NOW — FOLLOW-UP===\nAdd ONE short follow-up sentence (max ~25 words) that reacts to what was just said. Sharpen an accusation, defend yourself, or call out someone's silence. Always say something concrete — no filler."
    end
    p:add_user(tail .. directive)
    return p
end

local function build_vote_prompt(state)
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
    local vote_mode = "vote"
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
        suspicion = state.suspicion,
        roster_names = state.roster_names,
        slot = state.slot,
    }, vote_mode)
    local directive = [[


===VOTE NOW===
Update your private suspicion of each named player in this round, then cast your vote.
Rules:
- suspicion_updates are DELTAS in [-20, +20] keyed by player NAME. Add for Mafia-aligned behavior, subtract for Villager-aligned behavior.
- reflection_notes are short (<=60 chars) per-player reads this round, keyed by NAME.
- vote_target MUST be the NAME of a living non-self player. Abstention is not allowed — you are required to vote even with imperfect information. Pick whoever feels most suspicious right now.
- reasoning must quote or clearly reference something a specific player said today; address them by name.
- Do NOT vote for yourself. Do NOT bandwagon without a specific reason.]]
    p:add_user(tail .. directive)
    return p
end

-- Section G: suspicion update helper ----------------------------------------

local function apply_suspicion_updates(state, updates, reflection_notes)
    state.suspicion = state.suspicion or {}
    for name, delta in pairs(updates or {}) do
        local slot = state.name_to_slot[name]
        if slot and slot ~= state.slot then
            local current = state.suspicion[slot]
            local curr_value
            if type(current) == "table" then
                curr_value = current.value or 50
            else
                curr_value = current or 50
            end
            local new_value = curr_value + delta
            if new_value < 0 then new_value = 0 end
            if new_value > 100 then new_value = 100 end
            local note = reflection_notes and reflection_notes[name] or nil
            state.suspicion[slot] = { value = new_value, reflection_note = note }
        end
    end
end

-- Section H: event log helpers ----------------------------------------------

local EVENT_LOG_CAP = 200

--- unpack_event — extract (kind, data) from a subscription-channel event
--- via pairs() to bypass the linter's process.Event narrowing.
local function unpack_event(evt)
    if type(evt) ~= "table" then return nil, nil end
    local kind, data
    for k, v in pairs(evt) do
        if k == "kind" then kind = v end
        if k == "data" then data = v end
    end
    return kind, data
end

local function event_to_log_entry(kind, data)
    local scope, text, from_slot, victim_slot, revealed_role, cause, round_num
    if type(data) == "table" then
        for k, v in pairs(data) do
            if k == "scope" then scope = v end
            if k == "text" then text = v end
            if k == "message" and not text then text = v end
            if k == "from_slot" then from_slot = v end
            if k == "victim_slot" then victim_slot = v end
            if k == "revealed_role" then revealed_role = v end
            if k == "cause" then cause = v end
            if k == "round" then round_num = v end
        end
    end
    return {
        scope = scope,
        kind = kind,
        text = text or "",
        from_slot = from_slot,
        victim_slot = victim_slot,
        revealed_role = revealed_role,
        cause = cause,
        round = round_num,
    }
end

local function append_event(state, entry)
    table.insert(state.event_log, entry)
    -- Soft cap: evict oldest entries to prevent unbounded growth (T-03-02-06).
    if #state.event_log > EVENT_LOG_CAP then
        table.remove(state.event_log, 1)
    end
end

-- Section I: chat turn handler (blocking, non-streaming) -------------------
--
-- Phase 3.1 UX change: we no longer stream chunks to the orchestrator/SPA.
-- Instead the orchestrator publishes typing.started / typing.ended events
-- and the SPA renders a "{name} is typing..." placeholder bubble. Here we
-- just run llm.generate blocking (in a coroutine so we can race a timeout,
-- CANCEL, and abort.turn), then send the full text as a single chat.submit.

local function extract_generate_text(res)
    -- Authoritative Wippy shape (from vendor/wippy/llm/llm.lua normalize_response):
    --   { result = <string>, tokens, finish_reason, metadata, tool_calls }
    -- where `result` is the generated text itself as a STRING.
    -- Fallbacks below cover plain-string returns and tables that may carry
    -- `content`/`text` at the top level or nested — only used if `result`
    -- is missing.
    if type(res) == "string" then return res end
    if type(res) ~= "table" then return "" end
    -- Canonical case: result is a string.
    local r = nil
    for k, v in pairs(res) do
        if k == "result" then r = v end
    end
    if type(r) == "string" then return r end
    -- Defensive fallbacks (in case provider emits a non-canonical shape).
    if type(r) == "table" then
        for k2, v2 in pairs(r) do
            if (k2 == "content" or k2 == "text") and type(v2) == "string" then
                return v2
            end
        end
    end
    for k, v in pairs(res) do
        if (k == "content" or k == "text") and type(v) == "string" then
            return v
        end
    end
    return ""
end

local function run_chat_turn(state, round, is_mandatory)
    assert_stable_hash(state)
    state.round = round

    local p = build_chat_prompt(state, is_mandatory)

    -- Blocking generate in a coroutine so the main select loop can still
    -- race a deadline, CANCEL, and abort.turn against the LLM call.
    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.generate(p, {
            model = MODEL,
            max_tokens = 80,
        })
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
            persist_error(state.npc_id, "chat", { type = "TIMEOUT", message = CHAT_CAP_S }, 0)
            process.send(state.parent_pid, "chat.decline", {
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
                local cls = classify(rv_err)
                persist_error(state.npc_id, "chat", rv_err, 0)
                process.send(state.parent_pid, "chat.decline", {
                    from_slot = state.slot, round = round,
                    reason = "llm_" .. (cls.reason or "error"),
                })
                pe.publish_event("system", "npc_turn_skipped", "/" .. state.game_id, {
                    npc_id = state.npc_id, slot = state.slot, round = round, reason = "chat_gen_error",
                })
                return
            end
            local full = extract_generate_text(rv_res)
            -- Defensive: strip a trailing "DECLINE" / "DECLINED" token in
            -- case the model echoes the word from cached context. Both
            -- turns are mandatory; DECLINE is never instructed.
            full = full:gsub("[%s%p]*[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]?[%s%p]*$", "")
            process.send(state.parent_pid, "chat.submit", {
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
                    process.send(state.parent_pid, "chat.decline", {
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

-- Section J: last-words handler ---------------------------------------------

local function run_last_words(state, round)
    assert_stable_hash(state)
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
        persist_error(state.npc_id, "last_words", { type = "TIMEOUT" }, 0)
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
        persist_error(state.npc_id, "last_words", rv_err, 0)
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

    -- Extract text — framework/llm non-streaming returns res.result (string) per npc_test.lua call_chat.
    local text = ""
    if type(rv_res) == "table" then
        for k, v in pairs(rv_res) do
            if k == "result" and type(v) == "string" then text = v end
            if k == "content" and type(v) == "string" and text == "" then text = v end
            if k == "text" and type(v) == "string" and text == "" then text = v end
        end
    elseif type(rv_res) == "string" then
        text = rv_res
    end
    if type(text) ~= "string" then text = tostring(text) end

    -- Non-empty guard: wrong field path silently returns "" which breaks NPC-09.
    -- If this assert fires on first run, inspect the logged `keys` above and
    -- pick the correct field.
    assert(#text > 0, string.format(
        "[npc] run_last_words extracted empty text — wrong field path? npc=%s res_keys=%s",
        state.npc_id, table.concat(keys, ",")))
    return text
end

-- Section K: vote turn handler ----------------------------------------------

local function run_vote_turn(state, round)
    assert_stable_hash(state)
    state.round = round
    local p = build_vote_prompt(state)

    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.structured_output(VOTE_SCHEMA, p, { model = MODEL })
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        persist_error(state.npc_id, "vote", { type = "TIMEOUT", message = "15s cap" }, 0)
        process.send(state.parent_pid, "vote.cast", {
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
        persist_error(state.npc_id, "vote", rv_err, 0)
        process.send(state.parent_pid, "vote.cast", {
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

    apply_suspicion_updates(state, res_suspicion_updates, res_reflection_notes)
    local ok, perr = persist_suspicion_snapshot(state.npc_id, state.game_id, round, state.suspicion)
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

    process.send(state.parent_pid, "vote.cast", {
        from_slot = state.slot,
        vote_for_slot = vote_for_slot,
        reasoning = res_reasoning,
        round = round,
    })
end

-- LOOP-02 (Villager-auto): respond to orchestrator's night.pick request.
-- Mafia-only handler. Returns {from_slot, target_slot, reasoning, confidence, round}
-- via process.send to parent_pid topic "night.pick.response".
-- Mirrors run_vote_turn shape (coroutine + llm.structured_output + channel.select).
-- Persona drift tripwire (assert_stable_hash) is the first thing we do — same as run_vote_turn.
local function run_night_pick(state, raw)
    assert_stable_hash(state)
    state.round = (raw.round and tonumber(raw.round)) or state.round or 0
    local round = state.round

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

    -- Build prompt: persona stable_block + cache marker + dynamic tail
    -- (event log + roster) + inline night-pick directive (mirrors run_last_words).
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
        suspicion = state.suspicion,
        roster_names = state.roster_names,
        slot = state.slot,
    }, "chat")
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

    local result_ch = channel.new(1)
    coroutine.spawn(function()
        local res, err = llm.structured_output(NIGHT_PICK_SCHEMA, p, { model = MODEL })
        result_ch:send({ res = res, err = err })
    end)
    local deadline = time.after(VOTE_CAP_S)
    local r = channel.select({ result_ch:case_receive(), deadline:case_receive() })

    if not r.ok or r.channel ~= result_ch then
        persist_error(state.npc_id, "night_pick", { type = "TIMEOUT", message = tostring(VOTE_CAP_S) }, 0)
        process.send(state.parent_pid, "night.pick.response", {
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
        persist_error(state.npc_id, "night_pick", rv_err, 0)
        process.send(state.parent_pid, "night.pick.response", {
            from_slot = state.slot,
            target_slot = fallback_slot,
            reasoning = "llm_error",
            confidence = 0,
            round = round,
        })
        return
    end

    -- framework/llm wraps structured_output as { result = <schema_table>, ... }
    local res_table = {}
    if type(rv_res) == "table" then
        local inner = nil
        for k, v in pairs(rv_res) do
            if k == "result" and type(v) == "table" then inner = v end
        end
        res_table = inner or rv_res
    end

    local target_slot = nil
    local reasoning = ""
    local confidence = 0
    for k, v in pairs(res_table) do
        if k == "target_slot" then target_slot = tonumber(v) end
        if k == "reasoning" then reasoning = tostring(v) end
        if k == "confidence" then confidence = tonumber(v) or 0 end
    end

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

    process.send(state.parent_pid, "night.pick.response", {
        from_slot = state.slot,
        target_slot = target_slot,
        reasoning = reasoning,
        confidence = confidence,
        round = round,
    })
end

-- Section L: main loop + boot -----------------------------------------------

local function main_loop(state, public_sub, mafia_sub, system_sub,
                         public_ch, mafia_ch, system_ch, proc_ev)
    local inbox = process.inbox()

    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if public_ch then table.insert(cases, public_ch:case_receive()) end
        if mafia_ch  then table.insert(cases, mafia_ch:case_receive())  end
        if system_ch then table.insert(cases, system_ch:case_receive()) end

        local r = channel.select(cases)
        if not r.ok then
            if public_sub then public_sub:close() end
            if mafia_sub  then mafia_sub:close()  end
            if system_sub then system_sub:close() end
            return
        end

        if r.channel == inbox then
            local msg = r.value
            local tp = msg:topic()
            local raw = msg:payload():data() or {}

            if tp == "day.turn" then
                if state.dead then
                    logger:info("[npc] dead; skipping day.turn", { npc = state.npc_id })
                else
                    local turn_round = 0
                    local is_mandatory = true
                    for k, v in pairs(raw) do
                        if k == "round" then turn_round = v end
                        if k == "is_mandatory" then is_mandatory = (v ~= false) end
                    end
                    run_chat_turn(state, turn_round, is_mandatory)
                end

            elseif tp == "vote.prompt" then
                if state.dead then
                    logger:info("[npc] dead; skipping vote.prompt", { npc = state.npc_id })
                    local vote_round = 0
                    for k, v in pairs(raw) do
                        if k == "round" then vote_round = v end
                    end
                    process.send(state.parent_pid, "vote.cast", {
                        from_slot = state.slot, vote_for_slot = nil,
                        reasoning = "dead", round = vote_round,
                    })
                else
                    local vote_round = 0
                    for k, v in pairs(raw) do
                        if k == "round" then vote_round = v end
                    end
                    run_vote_turn(state, vote_round)
                end

            elseif tp == "night.pick" then
                if state.dead then
                    logger:info("[npc] dead; skipping night.pick", { npc = state.npc_id })
                elseif state.role ~= "mafia" then
                    logger:warn("[npc] non-mafia received night.pick; dropping",
                        { npc = state.npc_id, role = state.role })
                else
                    run_night_pick(state, raw)
                end

            elseif tp == "eliminated" then
                local elim_slot = nil
                local elim_round = 0
                local request_lw = false
                for k, v in pairs(raw) do
                    if k == "slot" then elim_slot = v end
                    if k == "round" then elim_round = v end
                    if k == "request_last_words" then request_lw = (v == true) end
                end
                if elim_slot == state.slot then
                    state.dead = true
                    logger:info("[npc] eliminated", { npc = state.npc_id, round = elim_round })
                    if request_lw then
                        local text, err = run_last_words(state, elim_round)
                        if text and text ~= "" then
                            process.send(state.parent_pid, "chat.submit", {
                                from_slot = state.slot, round = elim_round,
                                text = text, kind = "last_words",
                            })
                        else
                            logger:warn("[npc] last_words failed", {
                                npc = state.npc_id, err = tostring(err),
                            })
                        end
                    end
                    -- DO NOT return — orchestrator sends CANCEL; main_loop CANCEL branch handles exit.
                end

            else
                logger:debug("[npc] unhandled inbox topic", {
                    npc = state.npc_id, topic = tostring(tp),
                })
            end

        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                if public_sub then public_sub:close() end
                if mafia_sub  then mafia_sub:close()  end
                if system_sub then system_sub:close() end
                logger:info("[npc] CANCEL; exiting", { npc = state.npc_id })
                return
            end

        elseif r.channel == public_ch then
            -- Accumulate events into log for prompt context (NPC-06).
            -- Skip chat.chunk — streaming chunks are transient and each
            -- chunk would otherwise become a log entry, flooding the
            -- prompt. Only chat.line (the committed bubble) is narrative.
            local kind, data = unpack_event(r.value)
            if kind and kind ~= "chat.chunk" then
                append_event(state, event_to_log_entry(kind, data))
            end

        elseif mafia_ch and r.channel == mafia_ch then
            local kind, data = unpack_event(r.value)
            if kind then
                append_event(state, event_to_log_entry(kind, data))
            end

        elseif system_ch and r.channel == system_ch then
            -- System scope carries many orchestration events
            -- (game_state_changed, chat_locked, npc_turn_skipped). Only
            -- the genuinely narrative ones belong in the NPC's prompt:
            -- night.resolved tells them someone was killed at night,
            -- and vote.tied tells them the vote failed to lynch.
            local kind, data = unpack_event(r.value)
            if kind == "night.resolved" or kind == "vote.tied" then
                append_event(state, event_to_log_entry(kind, data))
            end

        end
    end
end

local function run(args)
    args = args or {}
    local game_id = args.game_id
    local slot = args.slot
    local role = args.role
    local parent_pid = args.parent_pid

    if not (game_id and slot and role and parent_pid) then
        logger:error("[npc] missing required args", { args = tostring(args) })
        return
    end

    local NPC_ID = string.format("npc:%s:%d", game_id, slot)

    -- 1. Build stable persona block from spawn args (parameterized per D-01/D-03).
    local persona_args = {
        archetype            = args.archetype or persona.FIXTURE.archetype,
        name                 = args.name or persona.FIXTURE.name,
        voice_quirk          = args.voice_quirk or persona.FIXTURE.voice,
        canonical_utterances = args.canonical_utterances or {},
        role                 = role,
        partner_name         = args.mafia_partner_name,
        roster_names         = args.roster_names or {},
        rules_text           = persona.RULES,
    }
    local stable_block = tostring(persona.render_stable_block(persona_args))
    local stable_hash = hash.sha256(stable_block)
    -- Cache-minimum diagnostic (Pitfall 1 — >=4096 tokens on haiku-4-5).
    -- Token approximation: ~4 chars/token.
    logger:info("[npc] stable_block built", {
        npc = NPC_ID, hash = stable_hash, bytes = #stable_block,
        tokens_est = math.floor(#stable_block / 4),
    })
    if (#stable_block / 4) < 4096 then
        logger:warn("[npc] stable_block under 4096-token cache minimum", {
            npc = NPC_ID, tokens_est = math.floor(#stable_block / 4),
        })
    end

    -- 2. Registry register BEFORE subscribe (Pitfall 1).
    local reg_ok, reg_err = process.registry.register(NPC_ID)
    if not reg_ok then
        logger:error("[npc] registry.register failed", { npc = NPC_ID, err = tostring(reg_err) })
        return
    end

    -- 3. Subscribe BEFORE ready-ack.
    -- scope_allowed permits `system` for both roles (villager + mafia),
    -- so we subscribe to mafia.system for night.resolved / vote.tied
    -- narrative events. The main_loop filters the specific kinds it cares
    -- about (see system_ch handler) to avoid polluting the prompt with
    -- game_state_changed / chat_locked chatter.
    local public_sub = events.subscribe("mafia.public", "*")
    local system_sub = events.subscribe("mafia.system", "*")
    local mafia_sub = nil
    if role == "mafia" then
        mafia_sub = events.subscribe("mafia.mafia", "*")
    end
    local public_ch = public_sub and public_sub:channel() or nil
    local mafia_ch  = mafia_sub  and mafia_sub:channel()  or nil
    local system_ch = system_sub and system_sub:channel() or nil
    local proc_ev = process.events()

    -- 4. Rehydrate suspicion from last snapshot (NPC-08 restart survival).
    local suspicion = rehydrate_suspicion(NPC_ID, game_id)

    -- 5. Ready handshake.
    process.send(parent_pid, "npc.ready", { slot = slot })
    logger:info("[npc] ready", { npc = NPC_ID, role = role })

    -- 6. State table carried through handlers.
    local state = {
        npc_id       = NPC_ID,
        game_id      = game_id,
        slot         = slot,
        role         = role,
        parent_pid   = parent_pid,
        stable_block = stable_block,
        stable_hash  = stable_hash,
        persona_args = persona_args,
        name         = args.name,
        name_to_slot = args.name_to_slot or {},
        roster_names = args.roster_names or {},
        suspicion    = suspicion,
        event_log    = {},
        roster       = {},
        round        = 0,
        dead         = false,
    }

    -- 7. Main loop.
    main_loop(state, public_sub, mafia_sub, system_sub,
              public_ch, mafia_ch, system_ch, proc_ev)
end

return { run = run }
