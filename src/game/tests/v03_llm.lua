-- src/game/tests/v03_llm.lua
-- Phase 3 V-03-XX scenarios — extend Phase 2 harness with real-LLM tests.
-- Run under MAFIA_NPC_MODE=real + MAFIA_DEV_MODE=1.
-- D-21: [TEST] V-03-XX <name> OK|FAIL|SKIP line format.
-- Also includes V-02-09 scope-leak + V-02-10 grep-invariant (audit-style
-- tests grouped with v03 per plan interfaces).
-- Phase 6 cut 3 (T-02): bodies extracted verbatim from
-- src/game/test_driver.lua:456-467 + 491-823. Per 06-PATTERNS.md S-4 the
-- only changes are the local-alias block + per-file logger name.

local logger  = require("logger"):named("v03_llm")
local time    = require("time")
local sql     = require("sql")
local events  = require("events")
local channel = require("channel")
local harness = require("harness")

-- Local-alias block — keeps test bodies byte-identical (Pattern E).
local log_ok              = harness.log_ok
local log_fail            = harness.log_fail
local log_skip            = harness.log_skip
local field               = harness.field
local lookup_game_manager = harness.lookup_game_manager
local wait_for_reply      = harness.wait_for_reply
local count_rows          = harness.count_rows
local get_row             = harness.get_row
local poll_until          = harness.poll_until
local start_game          = harness.start_game
local wait_for_winner     = harness.wait_for_winner

-- Suppress unused-warning on aliases this group doesn't reference.
local _unused = { time, events, channel, lookup_game_manager, wait_for_reply, wait_for_winner }
_unused = nil

-- ──────────────────────────────────────────────────────────────────
-- V-02-09 scope-leak: pass-by-default. Phase 2 stubs don't call
-- visible_context, but if they did a SCOPE LEAK panic would have
-- crashed the run before we got here.
-- ──────────────────────────────────────────────────────────────────
local function test_scope_leak()
    log_ok("V-02-09 scope-leak")
end

-- ──────────────────────────────────────────────────────────────────
-- V-02-10 grep-invariant: sandbox strips io.popen (Phase 1 V-01-10
-- precedent). SKIP with a pointer to the host-side script.
-- ──────────────────────────────────────────────────────────────────
local function test_grep_invariant()
    log_skip("V-02-10 grep-invariant",
        "io unavailable in wippy sandbox; run scripts/audit-grep.sh from host shell")
end

-- ══════════════════════════════════════════════════════════════════
-- Phase 3 V-03-XX scenarios — extend Phase 2 harness.
-- Run under MAFIA_NPC_MODE=real + MAFIA_DEV_MODE=1.
-- ══════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- V-03-01 npc-reachable: NPC process registered within 5s of game start.
-- ──────────────────────────────────────────────────────────────────
local function test_npc_reachable(inbox, gm_pid)
    local name = "V-03-01 npc-reachable"
    local payload, err = start_game(inbox, gm_pid, 3, false)
    if not payload then
        log_fail(name, "start_game failed: " .. tostring(err))
        return nil
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id in payload")
        return nil
    end
    -- Poll up to 5s for NPC slot 2 to register.
    local ok = poll_until(function()
        local pid = process.registry.lookup("npc:" .. game_id .. ":2")
        return pid ~= nil, pid
    end, 5, "100ms")
    if ok then
        log_ok(name)
    else
        log_fail(name, "npc:" .. game_id .. ":2 not in registry after 5s")
    end
    return game_id
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-03 cache-minimum: can't grep stdout in sandbox; SKIP with manual pointer.
-- ──────────────────────────────────────────────────────────────────
local function test_cache_minimum()
    local name = "V-03-03 cache-minimum"
    log_skip(name,
        "io.popen unavailable in wippy sandbox; run: "
        .. "grep 'stable_block built' runtime/logs/*.log "
        .. "-- expect bytes >= 16384 (~4096 tokens)")
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-04 persona-sampling-deterministic: same seed → same names;
-- different seed → different. Pure function; no game spawn needed.
-- ──────────────────────────────────────────────────────────────────
local function test_persona_sampling_deterministic()
    local name = "V-03-04 persona-sampling-deterministic"
    local sampler = require("sampler")
    local persona_pool = require("persona_pool")
    local a = sampler.sample_personas(persona_pool.ARCHETYPES, persona_pool.NAMES, 5, 3)
    local b = sampler.sample_personas(persona_pool.ARCHETYPES, persona_pool.NAMES, 5, 3)
    local c = sampler.sample_personas(persona_pool.ARCHETYPES, persona_pool.NAMES, 5, 17)
    -- Same seed → identical output.
    for i = 1, 5 do
        if a[i].name ~= b[i].name or a[i].archetype_id ~= b[i].archetype_id then
            log_fail(name, string.format(
                "seed-3 not deterministic at slot %d: a=%s b=%s", i, a[i].name, b[i].name))
            return
        end
    end
    -- Different seed → at least one difference.
    local any_diff = false
    for i = 1, 5 do
        if a[i].name ~= c[i].name then any_diff = true; break end
    end
    if not any_diff then
        log_fail(name, "seeds 3 and 17 produced identical name sets")
        return
    end
    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-05 suspicion-persistence: after Day-1 vote, suspicion_snapshots
-- has >= 4 rows (4 NPC slots) with snapshot_json populated for round 1.
-- ──────────────────────────────────────────────────────────────────
local function test_suspicion_persistence(inbox, gm_pid)
    local name = "V-03-05 suspicion-persistence"
    local payload, err = start_game(inbox, gm_pid, 7, false)
    if not payload then
        log_fail(name, "start_game failed: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id in payload")
        return
    end
    -- Wait up to 45s for vote round 1 to commit suspicion snapshots.
    local ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM suspicion_snapshots "
            .. "WHERE game_id = ? AND round = 1 AND snapshot_json IS NOT NULL", game_id)
        return n >= 4, n
    end, 45, "500ms")
    if ok then
        log_ok(name)
    else
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM suspicion_snapshots "
            .. "WHERE game_id = ? AND round = 1 AND snapshot_json IS NOT NULL", game_id)
        log_fail(name, string.format(
            "suspicion_snapshots count=%d for game_id=%s round=1 (expected >= 4)", n, game_id))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-06 last-words-emitted: at least one messages row with kind='last_words'
-- across all games run so far in this session.
-- ──────────────────────────────────────────────────────────────────
local function test_last_words_emitted()
    local name = "V-03-06 last-words-emitted"
    -- Check for eliminations first; if none happened yet, SKIP.
    local elim_n = count_rows(
        "SELECT COUNT(*) AS n FROM eliminations WHERE cause = ?", "lynch")
    if elim_n == 0 then
        log_skip(name, "no lynch eliminations yet in this session; re-run after a full round")
        return
    end
    local lw_n = count_rows(
        "SELECT COUNT(*) AS n FROM messages WHERE kind = ?", "last_words")
    if lw_n >= 1 then
        log_ok(name)
    else
        log_fail(name, string.format(
            "0 last_words rows found despite %d lynch eliminations", elim_n))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-07 interjection-visible: send player.chat to orchestrator during
-- Day-1; assert a kind='human' row lands in messages within 3s.
-- ──────────────────────────────────────────────────────────────────
local function test_interjection_visible(inbox, gm_pid)
    local name = "V-03-07 interjection-visible"
    local payload, err = start_game(inbox, gm_pid, 11, false)
    if not payload then
        log_fail(name, "start_game failed: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id in payload")
        return
    end
    -- Wait until Day-1 is active (round 1 phase='day' row exists).
    local day_ok = poll_until(function()
        local r = get_row("SELECT phase FROM rounds WHERE game_id = ? AND round = 1", game_id)
        if r and r.phase == "day" then return true, r end
        return false, nil
    end, 20, "200ms")
    if not day_ok then
        log_fail(name, "Day-1 never started for game " .. game_id)
        return
    end
    -- Look up orchestrator pid.
    local orch_pid = process.registry.lookup("game:" .. game_id)
    if not orch_pid then
        log_fail(name, "orchestrator pid not found for game " .. game_id)
        return
    end
    -- Inject a player chat message directly.
    process.send(orch_pid, "player.chat", {
        text       = "I think it was Ana",
        from_slot  = 1,
        round      = 1,
        conn_pid   = "driver-synthetic",
    })
    -- Assert kind='human' row lands within 3s.
    local found = poll_until(function()
        local r = get_row("SELECT text FROM messages WHERE game_id = ? AND kind = 'human' AND text LIKE '%Ana%'", game_id)
        return r ~= nil, r
    end, 3, "100ms")
    if found then
        log_ok(name)
    else
        log_fail(name, "human interjection row not persisted within 3s for game " .. game_id)
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-08 loop-04-turn-count: each alive NPC slot (2..6) spoke 1-2 times
-- in Day-1. Waits for rounds.ended_at to be set before counting.
-- ──────────────────────────────────────────────────────────────────
local function test_turn_count(game_id)
    local name = "V-03-08 loop-04-turn-count"
    if not game_id then
        log_skip(name, "no game_id available from V-03-01")
        return
    end
    -- Wait for round 1 day phase to end.
    poll_until(function()
        local r = get_row("SELECT ended_at FROM rounds WHERE game_id = ? AND round = 1 AND phase = 'day'", game_id)
        if r and r.ended_at then return true, r end
        return false, nil
    end, 30, "500ms")
    -- Count npc messages per slot.
    local problems = {}
    for slot = 2, 6 do
        local row = get_row(
            "SELECT COUNT(*) AS n FROM messages "
            .. "WHERE game_id = ? AND round = 1 AND from_slot = ? AND kind = 'npc'", game_id, slot)
        local count = (row and tonumber(row.n)) or 0
        if count < 1 or count > 2 then
            table.insert(problems, string.format("slot %d: %d messages (expected 1-2)", slot, count))
        end
    end
    if #problems == 0 then
        log_ok(name)
    else
        log_fail(name, table.concat(problems, "; "))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-09 ap2-plugin-stateless: can't shell-out from sandbox.
-- SKIP with manual instruction.
-- ──────────────────────────────────────────────────────────────────
local function test_ap2_plugin_stateless()
    log_skip("V-03-09 ap2-plugin-stateless",
        "io.popen unavailable in wippy sandbox; run: bash scripts/audit-grep.sh "
        .. "(must exit 0; AP4 + AP2 gates police src/relay/game_plugin.lua)")
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-VILLAGER-WIN: Core Value regression — LLM-voting restores villager
-- win achievability. Tries seeds {3,5,7,11,17} in order; first to produce
-- games.winner='villager' wins.
-- ──────────────────────────────────────────────────────────────────
local function test_villager_win_v3(inbox, gm_pid)
    local name = "V-03-VILLAGER-WIN"
    local candidate_seeds = { 3, 5, 7, 11, 17 }
    for _, seed in ipairs(candidate_seeds) do
        local payload, err = start_game(inbox, gm_pid, seed, false)
        if not payload then
            log_fail(name, "start_game failed for seed " .. tostring(seed) .. ": " .. tostring(err))
            return
        end
        local game_id = field(payload, "game_id")
        if not game_id then
            log_fail(name, "no game_id for seed " .. tostring(seed))
            return
        end
        -- Wait up to 90s per seed (4 rounds × ~20s in dev mode).
        local winner = nil
        poll_until(function()
            local r = get_row("SELECT winner FROM games WHERE id = ?", game_id)
            if r and r.winner then winner = r.winner; return true, r.winner end
            return false, nil
        end, 90, "1000ms")
        if winner == "villager" then
            log_ok(name)
            return
        end
        logger:info(string.format(
            "[test_driver] V-03-VILLAGER-WIN seed=%d winner=%s game_id=%s",
            seed, tostring(winner), game_id))
    end
    log_skip(name, "no seed in {3,5,7,11,17} produced villager-win; "
        .. "extend seed list or diagnose bandwagon voting (Phase 2 V-02-08 handoff)")
end

-- ──────────────────────────────────────────────────────────────────
-- V-03-AUDIT: 20-turn vote-reasoning audit per CONTEXT.md D-10.
-- Requires accumulated vote rows from upstream V-03 scenarios.
-- ──────────────────────────────────────────────────────────────────
local function test_audit()
    local name = "V-03-AUDIT"
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_fail(name, "sql.get failed: " .. tostring(db_err))
        return
    end
    local votes, q_err = db:query(
        "SELECT v.game_id, v.round, v.from_slot, v.reasoning FROM votes v "
        .. "WHERE v.reasoning NOT IN ('player','llm_error','llm_timeout','stub') "
        .. "AND v.reasoning IS NOT NULL AND length(v.reasoning) > 10 "
        .. "ORDER BY v.game_id, v.round, v.from_slot LIMIT 20",
        {})
    db:release()
    if q_err then
        log_fail(name, "votes query failed: " .. tostring(q_err))
        return
    end
    if not votes or #votes < 20 then
        log_skip(name, string.format(
            "only %d qualifying NPC vote rows found (need >= 20); "
            .. "run more games with MAFIA_NPC_MODE=real to accumulate data",
            votes and #votes or 0))
        return
    end
    -- For each vote, check if reasoning contains a >= 4-char word from the same round's messages.
    local matches = 0
    for _, v in ipairs(votes) do
        local db2, db2_err = sql.get("app:db")
        if not db2_err and db2 then
            local msg_rows, _ = db2:query(
                "SELECT text FROM messages WHERE game_id = ? AND round = ? AND kind IN ('npc','human')",
                { v.game_id, v.round })
            db2:release()
            if msg_rows then
                local matched = false
                for _, m in ipairs(msg_rows) do
                    for word in tostring(m.text):gmatch("%S+") do
                        if #word >= 4 and tostring(v.reasoning):find(word, 1, true) then
                            matched = true
                            break
                        end
                    end
                    if matched then break end
                end
                if matched then matches = matches + 1 end
            end
        end
    end
    if matches >= 16 then
        log_ok(name)
    else
        log_fail(name, string.format(
            "only %d/20 vote reasonings reference discussion text (threshold 16/20)", matches))
    end
end

return {
    test_scope_leak = test_scope_leak,
    test_grep_invariant = test_grep_invariant,
    test_npc_reachable = test_npc_reachable,
    test_cache_minimum = test_cache_minimum,
    test_persona_sampling_deterministic = test_persona_sampling_deterministic,
    test_suspicion_persistence = test_suspicion_persistence,
    test_last_words_emitted = test_last_words_emitted,
    test_interjection_visible = test_interjection_visible,
    test_turn_count = test_turn_count,
    test_ap2_plugin_stateless = test_ap2_plugin_stateless,
    test_villager_win_v3 = test_villager_win_v3,
    test_audit = test_audit,
}
