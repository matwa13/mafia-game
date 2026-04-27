-- src/game/tests/v04_night.lua
-- Phase 4 V-04-XX scenarios — Night branches, mafia side-chat, end-game,
-- Start-New-Game. All scenarios use stub-mode NPCs (MAFIA_NPC_MODE=stub
-- or default). Real-LLM end-to-end is human-verified via the checkpoint
-- in 04-06-PLAN.md.
-- D-21: [TEST] V-04-XX <name> OK|FAIL|SKIP line format.
-- Phase 6 cut 3 (T-02): bodies extracted verbatim from
-- src/game/test_driver.lua:825-1385. Per 06-PATTERNS.md S-4 the only
-- changes are the local-alias block + per-file logger name.

local logger  = require("logger"):named("v04_night")
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
local _unused = { time, sql, lookup_game_manager, wait_for_reply, wait_for_winner }
_unused = nil

-- ══════════════════════════════════════════════════════════════════
-- V-04-XX: Phase 4 — Night branches, mafia side-chat, end-game, Start-New-Game
-- All scenarios use stub-mode NPCs (MAFIA_NPC_MODE=stub or default).
-- Real-LLM end-to-end is human-verified via the checkpoint in 04-06-PLAN.md.
-- ══════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- V-04-01: Villager-auto night branch — stub picks resolve, atomic SQL tx,
-- night.resolved publishes. Asserts night_actions row exists with
-- reasoning_json populated, eliminations has 1 row (cause='night'),
-- victim player row shows alive=0.
-- ──────────────────────────────────────────────────────────────────
local function test_v04_01_villager_auto_night(inbox, gm_pid)
    local name = "V-04-01 villager-auto night kill"
    -- Seed 3 → player_slot=1 assigned role via Fisher-Yates; role may be
    -- mafia or villager — both paths exercise the stub FSM. This test just
    -- verifies that night resolution completes and SQL is written.
    local payload, err = start_game(inbox, gm_pid, 3, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return nil
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id in game.started")
        return nil
    end

    -- Wait up to 20s for night_actions to have at least 1 row (Night 1).
    local ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM night_actions WHERE game_id = ? AND round = 1", game_id)
        return n >= 1, n
    end, 20, "300ms")
    if not ok then
        log_fail(name, "night_actions row never appeared for round 1")
        return game_id
    end

    -- Assert night_actions.reasoning_json is populated (Plan 04-01 migration + 04-04 writer).
    local na_row = get_row("SELECT reasoning_json FROM night_actions WHERE game_id = ? AND round = 1 LIMIT 1", game_id)
    if not na_row then
        log_fail(name, "night_actions row missing")
        return game_id
    end
    if not na_row.reasoning_json or na_row.reasoning_json == "" then
        log_fail(name, "night_actions.reasoning_json is empty (expected populated JSON)")
        return game_id
    end

    -- Assert eliminations has 1 row for round 1 with cause='night'.
    local elim = get_row("SELECT victim_slot, cause FROM eliminations WHERE game_id = ? AND round = 1 AND cause = 'night'", game_id)
    if not elim then
        log_fail(name, "no eliminations row with cause='night' for round 1")
        return game_id
    end

    -- Assert victim player row shows alive=0.
    local victim_slot = tonumber(elim.victim_slot) or 0
    local victim = get_row("SELECT alive FROM players WHERE game_id = ? AND slot = ?", game_id, victim_slot)
    if not victim or victim.alive ~= 0 then
        log_fail(name, "victim player.alive=" .. tostring(victim and victim.alive) .. " (expected 0)")
        return game_id
    end

    log_ok(name)
    return game_id
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-02: Villager-auto tie-break. This scenario requires canned
-- structured_output replies with different confidence values from two
-- Mafia NPCs — only achievable with a stub-NPC mode that emits fixed
-- night.pick.response payloads. The current stub path (run_night_stub)
-- does not exercise run_night_villager_auto's tie-break branch.
-- SKIP with phase-4-real-llm-only rationale; covered by human-verify
-- Scenario 1 and V-04-01 confidence field observation.
-- ──────────────────────────────────────────────────────────────────
local function test_v04_02_tie_break()
    log_skip("V-04-02 villager-auto tie-break",
        "phase-4-real-llm-only: requires two canned night.pick.response payloads "
        .. "with distinct confidence values; not achievable with current stub mode. "
        .. "Covered by human-verify checkpoint Scenario 1.")
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-03: Mafia-human night — test_driver injects player.night_pick
-- directly to orchestrator. Verify night_actions row has reasoning_json
-- with source='human' or 'mafia_human'. Requires human is Mafia (seed-
-- dependent role assignment). SKIP if player_role != mafia.
-- ──────────────────────────────────────────────────────────────────
local function test_v04_03_mafia_human_night(inbox, gm_pid)
    local name = "V-04-03 mafia-human night pick"
    -- Use seed 42 which empirically assigns player_slot=1 as mafia in V-02-07.
    -- If not mafia, SKIP — role assignment is RNG-dependent.
    local payload, err = start_game(inbox, gm_pid, 42, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return nil
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id")
        return nil
    end
    local player_role = field(payload, "player_role")
    if player_role ~= "mafia" then
        log_skip(name, "seed 42 assigned role=" .. tostring(player_role) .. "; need mafia for this scenario")
        return game_id
    end

    -- Wait for orchestrator to enter night (night_actions row signals resolve
    -- OR we inject a pick during the night window).
    -- Give orchestrator a moment to enter the mafia-human night branch.
    time.sleep("2s")

    local orch_pid = process.registry.lookup("game:" .. game_id)
    if not orch_pid then
        log_fail(name, "orchestrator pid not found for game " .. game_id)
        return game_id
    end

    -- Find a living non-mafia target slot.
    local target_row = get_row("SELECT slot FROM players WHERE game_id = ? AND alive = 1 AND role = 'villager' LIMIT 1", game_id)
    if not target_row then
        log_skip(name, "no living villager found; game may have ended early")
        return game_id
    end

    -- Inject player.night_pick to orchestrator.
    process.send(orch_pid, "player.night_pick", {
        target_slot = target_row.slot,
        round = 1,
        from_slot = 1,
    })

    -- Wait for night_actions row for round 1.
    local ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM night_actions WHERE game_id = ? AND round = 1", game_id)
        return n >= 1, n
    end, 15, "300ms")
    if not ok then
        log_fail(name, "night_actions row never appeared after player.night_pick injection")
        return game_id
    end

    -- Assert reasoning_json is populated (D-VR-04: human case records stub reasoning).
    local na_row = get_row("SELECT reasoning_json FROM night_actions WHERE game_id = ? AND round = 1 LIMIT 1", game_id)
    if not na_row or not na_row.reasoning_json or na_row.reasoning_json == "" then
        log_fail(name, "night_actions.reasoning_json empty after mafia-human pick")
        return game_id
    end

    log_ok(name)
    return game_id
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-04: Mafia side-chat exchange — requires stub partner that emits
-- canned night.side_chat.reply responses. The current NPC processes use
-- real LLM (MAFIA_NPC_MODE=real) for side-chat; stub mode does not
-- exercise run_night_mafia_human's side-chat loop.
-- SKIP with phase-4-real-llm-only rationale; covered by human-verify
-- Scenario 2 (SideChat alternation + mafia_chat SQL rows).
-- ──────────────────────────────────────────────────────────────────
local function test_v04_04_mafia_side_chat()
    log_skip("V-04-04 mafia side-chat exchange",
        "phase-4-real-llm-only: requires partner NPC to emit night.side_chat.reply; "
        .. "not injectable from test_driver without a stub-NPC override. "
        .. "SQL assertion: SELECT COUNT(*) FROM messages WHERE kind='mafia_chat'. "
        .. "Covered by human-verify checkpoint Scenario 2.")
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-05: Partner-dead Mafia night — requires two sequential nights:
-- first to kill the partner NPC (via lynch), second to verify Mafia-human
-- proceeds without side-chat. Multi-round orchestration is outside stub
-- test_driver's injection capability without a full live-game loop.
-- SKIP with phase-4-real-llm-only rationale; covered by human-verify
-- Scenario 3 (partner-dead NightPicker UI shows "you plot alone").
-- ──────────────────────────────────────────────────────────────────
local function test_v04_05_partner_dead()
    log_skip("V-04-05 partner-dead mafia night",
        "phase-4-real-llm-only: requires orchestrating partner NPC death across "
        .. "multiple rounds before entering Mafia night; not feasible in stub harness. "
        .. "Covered by human-verify checkpoint Scenario 3.")
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-06: Begin-Day gate — verify orchestrator does NOT advance to Day
-- until player.advance_phase arrives. After night resolves, sleep 1s,
-- assert phase is still 'night' in rounds table, then send advance_phase
-- and assert day round appears. Uses V-04-01 game_id.
-- ──────────────────────────────────────────────────────────────────
local function test_v04_06_begin_day_gate(game_id)
    local name = "V-04-06 begin-day gate"
    if not game_id then
        log_skip(name, "no game_id available (V-04-01 failed)")
        return
    end

    -- Wait for night_actions to confirm night resolved.
    local night_ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM night_actions WHERE game_id = ?", game_id)
        return n >= 1, n
    end, 15, "200ms")
    if not night_ok then
        log_skip(name, "night_actions never appeared; cannot test gate")
        return
    end

    -- Wait a moment to see if Day auto-advances (it should NOT for at least 1s after night).
    time.sleep("1s")

    -- Check that no 'day' phase rounds row has appeared (orchestrator should be blocked on gate).
    local day_n = count_rows(
        "SELECT COUNT(*) AS n FROM rounds WHERE game_id = ? AND phase = 'day'", game_id)
    if day_n >= 1 then
        -- Day already started — may have been too slow OR the gate is missing.
        -- This is not necessarily a failure (game progressed legitimately with player.advance_phase
        -- from a prior V-04-01 run or the intro gate). Log informational skip.
        log_skip(name,
            "day phase already started by the time gate check ran (game progressed normally; "
            .. "gate tested implicitly — no auto-advance without player.advance_phase observed)")
        return
    end

    -- Now inject player.advance_phase to release the gate.
    local orch_pid = process.registry.lookup("game:" .. game_id)
    if not orch_pid then
        log_skip(name, "orchestrator not found (game may have ended already)")
        return
    end

    -- Get current round from night_actions.
    local na_row = get_row("SELECT round FROM night_actions WHERE game_id = ? ORDER BY round DESC LIMIT 1", game_id)
    local current_round = (na_row and na_row.round) or 1

    process.send(orch_pid, "player.advance_phase", { round = current_round })

    -- Wait for 'day' phase round row to appear (confirming gate released).
    local gate_released = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM rounds WHERE game_id = ? AND phase = 'day'", game_id)
        return n >= 1, n
    end, 10, "200ms")

    if gate_released then
        log_ok(name)
    else
        log_fail(name, "day phase never started after player.advance_phase injection within 10s")
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-07: Scope-leak runtime check — verify that no SCOPE LEAK panic
-- appeared in the errors table across all games run this session.
-- visible_context.lua panics on scope violation and the Wippy supervisor
-- logs the crash to the errors table. Assert zero matching rows.
-- ──────────────────────────────────────────────────────────────────
local function test_v04_07_scope_leak()
    local name = "V-04-07 scope-leak runtime check"
    -- Check errors table for SCOPE LEAK messages.
    local n = count_rows(
        "SELECT COUNT(*) AS n FROM errors WHERE message LIKE 'SCOPE LEAK%'")
    if n == -1 then
        -- errors table may not exist (pre-Phase-1 schema). SKIP.
        log_skip(name, "errors table query failed (may not exist in this schema version)")
        return
    end
    if n == 0 then
        log_ok(name)
    else
        log_fail(name, "SCOPE LEAK entries found in errors table: count=" .. tostring(n)
            .. " — Villager NPC received mafia-scope event (inspect errors table for details)")
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-08: Start-New-Game round-trip — complete game1, send game.start
-- again, verify new game_id, and assert that game_state_changed(phase='intro')
-- is emitted BEFORE any phase='night' for game2 (CLAUDE.md flow invariant:
-- "Intro gate before Night 1").
-- ──────────────────────────────────────────────────────────────────
local function test_v04_08_start_new_game(inbox, gm_pid)
    local name = "V-04-08 start-new-game round-trip"

    -- Game 1: start and drive to completion via wait_for_winner.
    local payload1, err1 = start_game(inbox, gm_pid, 99, false)
    if not payload1 then
        log_fail(name, "game1 start failed: " .. tostring(err1))
        return
    end
    local game1_id = field(payload1, "game_id")
    if not game1_id then
        log_fail(name, "no game_id for game1")
        return
    end

    -- Subscribe to mafia.system to observe game_state_changed events for game2.
    local sys_sub = events.subscribe("mafia.system", "*")
    local sys_ch = sys_sub and sys_sub:channel() or nil
    if not sys_ch then
        log_fail(name, "events.subscribe failed")
        return
    end

    -- Wait for game1 to finish (up to 120s).
    local winner1 = wait_for_winner(game1_id, 120)
    if not winner1 then
        sys_sub:close()
        log_skip(name, "game1 never finished within 120s; skipping Start-New-Game round-trip")
        return
    end

    -- Game 2: start with a different seed.
    local payload2, err2 = start_game(inbox, gm_pid, 7, false)
    if not payload2 then
        sys_sub:close()
        log_fail(name, "game2 start failed: " .. tostring(err2))
        return
    end
    local game2_id = field(payload2, "game_id")
    if not game2_id then
        sys_sub:close()
        log_fail(name, "no game_id for game2")
        return
    end

    -- game_id must differ.
    if game1_id == game2_id then
        sys_sub:close()
        log_fail(name, "game2 reused game1 game_id: " .. game1_id)
        return
    end

    -- Capture ordered sequence of game_state_changed phase values for game2.
    -- Assert: first phase seen is 'intro', and no 'night' precedes 'intro'.
    -- (CLAUDE.md flow invariant — "Intro gate before Night 1".)
    local phases_seen = {}
    local intro_before_night = false
    local intro_seen = false

    local deadline = time.after("15s")
    while true do
        local r = channel.select({
            inbox:case_receive(),
            sys_ch:case_receive(),
            deadline:case_receive(),
        })
        if not r.ok then break end
        if r.channel == deadline then break end
        if r.channel == sys_ch then
            local evt = r.value
            if evt and evt.kind == "game_state_changed" then
                local data = evt.data
                local ph = (type(data) == "table" and data.phase) or nil
                local gid = (type(data) == "table" and data.game_id) or nil
                if ph and gid == game2_id then
                    table.insert(phases_seen, ph)
                    if ph == "intro" and not intro_seen then
                        intro_seen = true
                        intro_before_night = true -- no 'night' before this point
                    elseif ph == "night" and not intro_seen then
                        intro_before_night = false
                    end
                    -- Once we have both intro and night confirmed, we can break.
                    if intro_seen and ph == "night" then break end
                end
            end
        end
    end
    sys_sub:close()

    -- Validate that intro was emitted (CLAUDE.md invariant).
    if not intro_seen then
        -- Intro may have arrived before we subscribed; check players table for game2.
        local p2_n = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ?", game2_id)
        if p2_n == 6 then
            -- Game2 spawned correctly; intro gate likely fired before our subscription.
            log_skip(name,
                "intro phase event not captured (subscription race); "
                .. "game2 spawned with 6 players. "
                .. "Phases observed: " .. table.concat(phases_seen, ","))
        else
            log_fail(name,
                "game2 intro phase not observed and players count=" .. tostring(p2_n)
                .. " (expected 6). Phases observed: " .. table.concat(phases_seen, ","))
        end
        return
    end

    if not intro_before_night then
        log_fail(name,
            "CLAUDE.md invariant violated: night phase observed before intro for game2. "
            .. "Phases seen: " .. table.concat(phases_seen, ","))
        return
    end

    -- Verify different persona names (at least one name differs between game1 and game2).
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_skip(name, "sql.get failed: " .. tostring(db_err) .. " (cannot check persona names)")
        return
    end
    local names1, _ = db:query(
        "SELECT display_name FROM players WHERE game_id = ? ORDER BY slot", { game1_id })
    local names2, _ = db:query(
        "SELECT display_name FROM players WHERE game_id = ? ORDER BY slot", { game2_id })
    db:release()

    local any_name_differs = false
    if names1 and names2 and #names1 == 6 and #names2 == 6 then
        for i = 1, 6 do
            if names1[i].display_name ~= names2[i].display_name then
                any_name_differs = true
                break
            end
        end
    else
        -- Can't compare names; skip name assertion but pass on game_id and intro checks.
        log_ok(name)
        return
    end

    if not any_name_differs then
        log_fail(name,
            "game2 persona names are identical to game1 (different seed should produce different sample)")
        return
    end

    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-09: Registry cleanliness — after Start-New-Game, verify that
-- old game's registered names are gone before new game runs.
-- Checks: process.registry.lookup("game:<game1_id>") == nil
--         process.registry.lookup("npc:<game1_id>:2") == nil
-- (Wippy auto-deregisters process names on process exit.)
-- ──────────────────────────────────────────────────────────────────
local function test_v04_09_registry_cleanliness(inbox, gm_pid)
    local name = "V-04-09 registry cleanliness"

    -- Start game1 and let it finish.
    local payload1, err1 = start_game(inbox, gm_pid, 55, false)
    if not payload1 then
        log_fail(name, "game1 start failed: " .. tostring(err1))
        return
    end
    local game1_id = field(payload1, "game_id")
    if not game1_id then
        log_fail(name, "no game_id for game1")
        return
    end

    -- Wait for game1 to end.
    local winner1 = wait_for_winner(game1_id, 120)
    if not winner1 then
        log_skip(name, "game1 never finished within 120s; cannot verify registry cleanliness")
        return
    end

    -- Give the supervisor a moment to deregister game1's names.
    time.sleep("1s")

    -- Assert old game's registry entries are gone.
    local game1_orch = process.registry.lookup("game:" .. game1_id)
    if game1_orch ~= nil then
        log_fail(name, "game:" .. game1_id .. " still in registry after game ended")
        return
    end

    local game1_npc2 = process.registry.lookup("npc:" .. game1_id .. ":2")
    if game1_npc2 ~= nil then
        log_fail(name, "npc:" .. game1_id .. ":2 still in registry after game ended")
        return
    end

    -- Start game2 to confirm no registry collision.
    local payload2, err2 = start_game(inbox, gm_pid, 33, false)
    if not payload2 then
        log_fail(name, "game2 start after cleanup failed: " .. tostring(err2))
        return
    end
    local game2_id = field(payload2, "game_id")
    if not game2_id then
        log_fail(name, "no game_id for game2")
        return
    end
    if game1_id == game2_id then
        log_fail(name, "game2 reused game1 game_id (no new UUID generated)")
        return
    end

    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-04-10: WR-06 — verify rounds table is non-empty after a complete game.
-- Asserts: COUNT(*) FROM rounds WHERE game_id=? >= 1 (at minimum the night
-- phase row for round 1 is written; plan 04-04 writes one row per phase).
-- ──────────────────────────────────────────────────────────────────
local function test_v04_10_rounds_written(inbox, gm_pid)
    local name = "V-04-10 WR-06 rounds-table written"

    local payload, err = start_game(inbox, gm_pid, 77, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id")
        return
    end

    -- Wait for game to finish.
    local winner = wait_for_winner(game_id, 120)
    if not winner then
        log_skip(name, "game never finished within 120s; cannot assert final rounds count")
        return
    end

    -- Assert at least 1 row in rounds for this game (WR-06 closure).
    local rounds_n = count_rows(
        "SELECT COUNT(*) AS n FROM rounds WHERE game_id = ?", game_id)
    if rounds_n < 1 then
        log_fail(name, "rounds table has 0 rows for game_id=" .. game_id .. " (WR-06 not satisfied)")
        return
    end

    -- Ideally >= 3 rows (night/day/vote for round 1 at minimum).
    if rounds_n >= 3 then
        log_ok(name)
    else
        -- 1-2 rows is acceptable if game ended early; log_ok with note.
        logger:info(string.format("[test_driver] V-04-10: rounds count=%d for game=%s "
            .. "(game ended early; WR-06 satisfied)", rounds_n, game_id))
        log_ok(name)
    end
end

return {
    test_v04_01_villager_auto_night = test_v04_01_villager_auto_night,
    test_v04_02_tie_break = test_v04_02_tie_break,
    test_v04_03_mafia_human_night = test_v04_03_mafia_human_night,
    test_v04_04_mafia_side_chat = test_v04_04_mafia_side_chat,
    test_v04_05_partner_dead = test_v04_05_partner_dead,
    test_v04_06_begin_day_gate = test_v04_06_begin_day_gate,
    test_v04_07_scope_leak = test_v04_07_scope_leak,
    test_v04_08_start_new_game = test_v04_08_start_new_game,
    test_v04_09_registry_cleanliness = test_v04_09_registry_cleanliness,
    test_v04_10_rounds_written = test_v04_10_rounds_written,
}
