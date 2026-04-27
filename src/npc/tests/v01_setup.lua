-- src/npc/tests/v01_setup.lua
-- Phase 1 V-01-XX scenario library — NPC reachability, restart, chat,
-- vote, scope-leak, persona-drift, and D-09 audit gate.
-- D-21: [TEST] <name> OK|FAIL|SKIP line format (preserved across the
-- cut by harness.log_ok/log_fail/log_skip).
-- Phase 6 cut 4 (T-04): bodies extracted verbatim from
-- src/npc/test_driver.lua:42-415 (has_anthropic_key + lookup_npc +
-- count_error_rows + 10 test_* fns). Per 06-PATTERNS.md S-4: only the
-- local-alias block + per-file logger name is new; test bodies are
-- byte-identical (no signature changes).

local logger  = require("logger"):named("v01_setup")
local time    = require("time")
local sql     = require("sql")
local env     = require("env")
local channel = require("channel")
local harness = require("harness")

-- Local-alias block — keeps test bodies byte-identical without rewriting
-- every `log_ok(...)` to `harness.log_ok(...)`. Pattern E.
local log_ok         = harness.log_ok
local log_fail       = harness.log_fail
local log_skip       = harness.log_skip
local wait_for_reply = harness.wait_for_reply
local field          = harness.field

-- Suppress unused-warning on aliases not used in this file (logger and
-- channel aren't called by every group, but we declare them to keep the
-- alias block uniform across vXX_*.lua files).
local _unused = { logger, channel }
_unused = nil

-- ──────────────────────────────────────────────────────────────────
-- V-01-specific helpers — kept local (not in shared harness) because
-- they're npc:test fixture-specific. Exported so test_driver.lua can
-- call lookup_npc for the initial boot-wait before scenario dispatch.
-- ──────────────────────────────────────────────────────────────────
local function has_anthropic_key()
    local key = env.get("ANTHROPIC_API_KEY")
    return key ~= nil and key ~= ""
end

-- Lookup-with-retry (extract from src/probes/probe.lua lines 126-138).
-- Supervisor initial_delay is 2s; after a forced cancel/panic the new
-- pid can land anywhere in 2-3s, so give ~3s of budget (30 × 100ms).
local function lookup_npc(max_attempts, delay)
    max_attempts = max_attempts or 20
    delay = delay or "100ms"
    local pid, err
    for _ = 1, max_attempts do
        pid, err = process.registry.lookup("npc:test")
        if pid then return pid end
        time.sleep(delay)
    end
    return nil, err
end

-- ──────────────────────────────────────────────────────────────────
-- Error-row counter. SQL acquire-per-read + release (Phase 0 idiom;
-- app:db handle is not held for the life of the driver).
-- ──────────────────────────────────────────────────────────────────
local function count_error_rows(call_type, since_ts)
    local db, err = sql.get("app:db")
    if err or not db then
        return -1, "sql.get: " .. tostring(err)
    end
    local rows, q_err = db:query(
        "SELECT COUNT(*) AS n FROM errors WHERE npc_id = ? AND call_type = ? AND ts >= ?",
        { "npc:test", call_type, since_ts }
    )
    db:release()
    if q_err or not rows or not rows[1] then
        return -1, tostring(q_err)
    end
    return rows[1].n, nil
end

-- ──────────────────────────────────────────────────────────────────
-- Per-test bodies. Each returns nothing; each emits exactly one
-- log_ok / log_fail / log_skip. A FAIL in one test does NOT abort the
-- driver — the next test still runs.
-- ──────────────────────────────────────────────────────────────────

-- [TEST] npc-reachable (V-01-01): ping → pong
local function test_npc_reachable(inbox)
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("npc-reachable", "lookup: " .. tostring(err))
    end
    local ok, send_err = process.send(pid, "ping", { reply_to = process.pid() })
    if not ok or send_err then
        return log_fail("npc-reachable", "send ping: " .. tostring(send_err))
    end
    local _, wait_err = wait_for_reply(inbox, "2s", "pong")
    if wait_err then
        return log_fail("npc-reachable", wait_err)
    end
    log_ok("npc-reachable")
end

-- [TEST] npc-restart (V-01-02): terminate → supervisor-restart → new pid
-- NOTE: Wippy distinguishes process.cancel (graceful; supervisor honours
-- the stop and does NOT restart) from process.terminate (forceful; treated
-- as abnormal exit → supervisor restart triggers). The plan text used
-- "cancel" informally; the operational intent ("supervisor restarts the
-- NPC when it dies unexpectedly") is only exercised by terminate. This is
-- tracked as a Rule 1 deviation in 01-05-SUMMARY.md.
local function test_npc_restart()
    local pid_before, err = lookup_npc(30, "100ms")
    if not pid_before then
        return log_fail("npc-restart", "pre-lookup: " .. tostring(err))
    end
    process.terminate(pid_before)
    -- Supervisor initial_delay is 2s; first restart can land 2-5s after
    -- terminate. 8s total budget (80 × 100ms).
    time.sleep("500ms")
    local pid_after, lookup_err = lookup_npc(80, "100ms")
    if not pid_after then
        return log_fail("npc-restart", "post-lookup: " .. tostring(lookup_err))
    end
    if pid_after == pid_before then
        return log_fail("npc-restart", "pid unchanged: " .. tostring(pid_before))
    end
    log_ok("npc-restart")
end

-- [TEST] chat-success (V-01-03): real LLM speak → non-empty text. Env-gated.
local function test_chat_success(inbox)
    if not has_anthropic_key() then
        return log_skip("chat-success", "no ANTHROPIC_API_KEY")
    end
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("chat-success", "lookup: " .. tostring(err))
    end
    local ok, send_err = process.send(pid, "speak", { reply_to = process.pid() })
    if not ok or send_err then
        return log_fail("chat-success", "send: " .. tostring(send_err))
    end
    -- 45s cap accounts for claude-haiku-4-5 latency (~15-25s typical). Full
    -- retry budget inside npc_test is 20s + 1s + 20s + 3s + 20s = ~64s, but a
    -- real happy-path call should return well within 45s on the first attempt.
    local msg, wait_err = wait_for_reply(inbox, "45s", "npc_message_done")
    if wait_err or not msg then
        return log_fail("chat-success", wait_err or "no reply")
    end
    local payload = msg:payload():data()
    local text = field(payload, "text")
    if type(text) ~= "string" or text == "" then
        return log_fail("chat-success", "empty text in ack")
    end
    log_ok("chat-success")
end

-- [TEST] chat-error-path (V-01-04): force_error RATE_LIMIT. Asserts 3 error rows
-- (2 retries + 1 final fallback per D-04/D-07) and the silent-skip ack.
local function test_chat_error_path(inbox)
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("chat-error-path", "lookup: " .. tostring(err))
    end
    local t0 = os.time()
    local ok, send_err = process.send(pid, "speak", {
        reply_to = process.pid(),
        force_error = true,
        error_type = "RATE_LIMIT",
    })
    if not ok or send_err then
        return log_fail("chat-error-path", "send: " .. tostring(send_err))
    end
    -- Backoffs are 1s + 3s per npc_test.lua BACKOFFS; give comfortable headroom.
    local _, wait_err = wait_for_reply(inbox, "15s", "npc_turn_skipped_ack")
    if wait_err then
        return log_fail("chat-error-path", wait_err)
    end
    local n, count_err = count_error_rows("chat", t0)
    if count_err then
        return log_fail("chat-error-path", "count: " .. tostring(count_err))
    end
    if n ~= 3 then
        return log_fail("chat-error-path", "expected 3 error rows, got " .. tostring(n))
    end
    log_ok("chat-error-path")
end

-- [TEST] vote-abstain (V-01-05): force_error TIMEOUT → vote_done with vote_target=nil
local function test_vote_abstain(inbox)
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("vote-abstain", "lookup: " .. tostring(err))
    end
    local t0 = os.time()
    local ok, send_err = process.send(pid, "vote", {
        reply_to = process.pid(),
        candidates = { 1, 2, 3 },
        force_error = true,
        error_type = "TIMEOUT",
    })
    if not ok or send_err then
        return log_fail("vote-abstain", "send: " .. tostring(send_err))
    end
    local msg, wait_err = wait_for_reply(inbox, "20s", "vote_done")
    if wait_err or not msg then
        return log_fail("vote-abstain", wait_err or "no reply")
    end
    local payload = msg:payload():data()
    local vote_target = field(payload, "vote_target")
    if vote_target ~= nil then
        return log_fail("vote-abstain", "expected nil target, got " .. tostring(vote_target))
    end
    local n, count_err = count_error_rows("vote", t0)
    if count_err then
        return log_fail("vote-abstain", "count: " .. tostring(count_err))
    end
    if n < 1 then
        return log_fail("vote-abstain", "expected ≥1 error row, got " .. tostring(n))
    end
    log_ok("vote-abstain")
end

-- [TEST] vote-success (V-01-06): real LLM vote returns integer target + reasoning. Env-gated.
local function test_vote_success(inbox)
    if not has_anthropic_key() then
        return log_skip("vote-success", "no ANTHROPIC_API_KEY")
    end
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("vote-success", "lookup: " .. tostring(err))
    end
    local ok, send_err = process.send(pid, "vote", {
        reply_to = process.pid(),
        candidates = { 1, 2, 3 },
    })
    if not ok or send_err then
        return log_fail("vote-success", "send: " .. tostring(send_err))
    end
    -- 30s cap matches claude-haiku-4-5 structured_output latency. Note the
    -- npc_test internal VOTE_CAP_S is 15s; one LLM call should return well
    -- within that. 30s gives headroom for a single retry (15s + 1s backoff).
    local msg, wait_err = wait_for_reply(inbox, "30s", "vote_done")
    if wait_err or not msg then
        return log_fail("vote-success", wait_err or "no reply")
    end
    local payload = msg:payload():data()
    local vote_target = field(payload, "vote_target")
    local reasoning = field(payload, "reasoning")
    local reason = field(payload, "reason")
    -- handle_vote emits vote_target=nil in TWO cases: (a) genuine LLM error
    -- (reason is set to the error-type string), (b) LLM returned schema-valid
    -- {"vote_target": null} meaning "abstain" (reason is absent; the success
    -- branch fires). Case (b) is a valid happy-path outcome for a prompt with
    -- no discriminating signal, so accept nil-with-reasoning. Case (a) —
    -- error fallback — must FAIL the test.
    if vote_target == nil then
        if reason then
            return log_fail("vote-success",
                "llm error path: reason=" .. tostring(reason))
        end
        if type(reasoning) ~= "string" or reasoning == "" then
            return log_fail("vote-success", "nil target with empty reasoning")
        end
        log_ok("vote-success")
        return
    end
    local valid = {
        [1] = true, [2] = true, [3] = true,
        ["1"] = true, ["2"] = true, ["3"] = true,
    }
    if not valid[vote_target] then
        return log_fail("vote-success",
            "target not in {1,2,3}: " .. tostring(vote_target))
    end
    if type(reasoning) ~= "string" or reasoning == "" then
        return log_fail("vote-success", "empty reasoning")
    end
    log_ok("vote-success")
end

-- [TEST] villager-no-mafia (V-01-07): no mafia-scoped events in the NPC's log
local function test_villager_no_mafia(inbox)
    local pid, err = lookup_npc(30, "100ms")
    if not pid then
        return log_fail("villager-no-mafia", "lookup: " .. tostring(err))
    end
    local ok, send_err = process.send(pid, "export_event_log", { reply_to = process.pid() })
    if not ok or send_err then
        return log_fail("villager-no-mafia", "send: " .. tostring(send_err))
    end
    local msg, wait_err = wait_for_reply(inbox, "3s", "event_log")
    if wait_err or not msg then
        return log_fail("villager-no-mafia", wait_err or "no reply")
    end
    local payload = msg:payload():data()
    local events_list = field(payload, "events")
    if type(events_list) ~= "table" then
        return log_fail("villager-no-mafia", "events missing or wrong type")
    end
    for i, e in ipairs(events_list) do
        local scope = field(e, "scope")
        if scope == "mafia" then
            return log_fail("villager-no-mafia",
                "mafia event at index " .. tostring(i))
        end
    end
    log_ok("villager-no-mafia")
end

-- [TEST] scope-leak-panic (V-01-08): inject mafia event + speak → D-11 panic → restart
local function test_scope_leak_panic()
    local pid_before, err = lookup_npc(30, "100ms")
    if not pid_before then
        return log_fail("scope-leak-panic", "pre-lookup: " .. tostring(err))
    end
    -- Fire-and-forget: inject_event has no ack, speak panics before any ack.
    process.send(pid_before, "inject_event", {
        scope = "mafia",
        kind = "mafia.night.pick",
        text = "bypass",
    })
    process.send(pid_before, "speak", { reply_to = process.pid() })
    time.sleep("500ms")
    local pid_after, lookup_err = lookup_npc(80, "100ms")
    if not pid_after then
        return log_fail("scope-leak-panic", "post-lookup: " .. tostring(lookup_err))
    end
    if pid_after == pid_before then
        return log_fail("scope-leak-panic", "pid unchanged (no supervisor restart)")
    end
    log_ok("scope-leak-panic")
end

-- [TEST] persona-drift-panic (V-01-09): mutate persona + speak → D-15 panic → restart
local function test_persona_drift_panic()
    local pid_before, err = lookup_npc(30, "100ms")
    if not pid_before then
        return log_fail("persona-drift-panic", "pre-lookup: " .. tostring(err))
    end
    process.send(pid_before, "mutate_persona", {})
    process.send(pid_before, "speak", { reply_to = process.pid() })
    time.sleep("500ms")
    local pid_after, lookup_err = lookup_npc(80, "100ms")
    if not pid_after then
        return log_fail("persona-drift-panic", "post-lookup: " .. tostring(lookup_err))
    end
    if pid_after == pid_before then
        return log_fail("persona-drift-panic", "pid unchanged (no supervisor restart)")
    end
    log_ok("persona-drift-panic")
end

-- [TEST] events-send-auditable (V-01-10): static D-09 audit — game code must
-- only reach events.send through the src/lib/events.lua wrapper. The Wippy
-- sandbox strips io.popen AND io.open, so this test always SKIPs in-process
-- and defers to a build-time grep audit (tracked as a Rule 3 deviation in
-- SUMMARY.md). src/probes/probe.lua is excluded by design.
local function test_events_send_auditable()
    -- Wippy sandbox strips the standard-library io table — io.open/io.popen
    -- are unavailable. V-01-10 always SKIPs in-process; the authoritative
    -- check is the build-time grep audit, listed below.
    return log_skip("events-send-auditable",
        "io unavailable in wippy sandbox; run manual audit: "
        .. "grep -rn 'events.send' src/ | grep -v src/lib/events.lua | grep -v src/probes/probe.lua")
end

return {
    has_anthropic_key          = has_anthropic_key,
    lookup_npc                 = lookup_npc,
    count_error_rows           = count_error_rows,
    test_npc_reachable         = test_npc_reachable,
    test_npc_restart           = test_npc_restart,
    test_chat_success          = test_chat_success,
    test_chat_error_path       = test_chat_error_path,
    test_vote_abstain          = test_vote_abstain,
    test_vote_success          = test_vote_success,
    test_villager_no_mafia     = test_villager_no_mafia,
    test_scope_leak_panic      = test_scope_leak_panic,
    test_persona_drift_panic   = test_persona_drift_panic,
    test_events_send_auditable = test_events_send_auditable,
}
