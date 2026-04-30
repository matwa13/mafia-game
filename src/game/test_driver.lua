-- src/game/test_driver.lua
-- Phase 6 cut 3 (Pattern B): supervised process body shrinks to a Pattern B
-- run() entry + scenario dispatch. The 11 harness helpers moved to
-- src/lib/test_harness.lua (T-03); the ~50 V-XX tests moved into
-- src/game/tests/vXX_*.lua phase-ID groups (T-02).
--
-- Phase 2 Plan 05 origin: 10-scenario test harness for the orchestrator FSM.
-- D-21: [TEST] V-XX-XX <name> OK|FAIL|SKIP line format (preserved across
-- the cut by harness.log_ok/log_fail/log_skip).
-- D-22: gated by MAFIA_DEV_MODE env var (driver idles if != "1").
-- Shape analog: src/npc/test_driver.lua (Phase 1 canonical).

local logger  = require("logger"):named("test_driver")
local channel = require("channel")
local env     = require("env")
local harness = require("harness")
local v02     = require("v02")
local v03     = require("v03")
local v04     = require("v04")
local v05     = require("v05")

-- ──────────────────────────────────────────────────────────────────
-- Main runner — sequential scenarios, then stay-alive-on-CANCEL.
-- ──────────────────────────────────────────────────────────────────
local function run(_args)
    local inbox = process.inbox()
    local dev_mode = env.get("MAFIA_DEV_MODE") == "1"

    if not dev_mode then
        logger:info("[test_driver] MAFIA_DEV_MODE != 1; driver idle")
    else
        logger:info("[test_driver] starting Phase 2 tests")

        if not v02.wait_for_schema(15) then
            logger:error("[test_driver] schema never landed; aborting scenarios")
        else
            local gm_pid = v02.test_boot()
            if gm_pid then
                local game_id = v02.test_spawn(inbox, gm_pid)
                if game_id then
                    v02.test_night_1_reveal(game_id)
                    v02.test_day_1_chat(game_id)
                    v02.test_vote_1_elim(game_id)
                end
                v02.test_forced_tie(inbox, gm_pid)
                v02.test_mafia_win(inbox, gm_pid)
                v02.test_villager_win(inbox, gm_pid)
                v03.test_scope_leak()
                v03.test_grep_invariant()
            end
        end

        logger:info("[test_driver] all Phase 2 tests complete")

        -- ── Phase 3 V-03-XX scenarios ──────────────────────────────────
        local npc_mode = env.get("MAFIA_NPC_MODE")
        if npc_mode == "real" then
            logger:info("[test_driver] MAFIA_NPC_MODE=real; starting Phase 3 V-03-XX tests")

            -- V-03-04: pure function — run first, no game needed.
            v03.test_persona_sampling_deterministic()

            -- V-03-01: boot a game; returns game_id for subsequent scenarios.
            local v03_gm_pid = process.registry.lookup("app.game:game_manager")
            local v03_game_id = nil
            if v03_gm_pid then
                v03_game_id = v03.test_npc_reachable(inbox, v03_gm_pid)
            else
                harness.log_fail("V-03-01 npc-reachable", "game_manager not found")
            end

            -- V-03-03: SKIP (sandbox constraint).
            v03.test_cache_minimum()

            -- V-03-05: fresh game to check suspicion persistence.
            if v03_gm_pid then
                v03.test_suspicion_persistence(inbox, v03_gm_pid)
            end

            -- V-03-08: turn count on the V-03-01 game (Day-1 should have finished by now).
            v03.test_turn_count(v03_game_id)

            -- V-03-06: last-words check (session-wide — any game that had a lynch).
            v03.test_last_words_emitted()

            -- V-03-07: interjection injection — fresh game.
            if v03_gm_pid then
                v03.test_interjection_visible(inbox, v03_gm_pid)
            end

            -- V-03-09: SKIP (sandbox constraint).
            v03.test_ap2_plugin_stateless()

            -- V-03-VILLAGER-WIN: Core Value — phase-gate scenario; no 60s cap.
            if v03_gm_pid then
                v03.test_villager_win_v3(inbox, v03_gm_pid)
            end

            -- V-03-AUDIT: 20-turn reasoning audit on accumulated vote rows.
            v03.test_audit()

            logger:info("[test_driver] Phase 3 V-03-XX scenarios complete "
                .. "— inspect log for individual OK|FAIL|SKIP lines")
            logger:info("[test_driver] D-09 + D-15 + AP4 + AP2 grep gate: bash scripts/audit-grep.sh")
        else
            logger:info("[test_driver] MAFIA_NPC_MODE=" .. tostring(npc_mode)
                .. "; skipping V-03-XX (require MAFIA_NPC_MODE=real)")
        end

        -- ── Phase 4 V-04-XX scenarios ──────────────────────────────────
        -- Run under MAFIA_DEV_MODE=1 (stub mode is fine; real-LLM is human-verified).
        logger:info("[test_driver] starting Phase 4 V-04-XX tests (stub-mode)")

        local v04_gm_pid = process.registry.lookup("app.game:game_manager")
        if not v04_gm_pid then
            logger:error("[test_driver] V-04-XX: game_manager not found; skipping Phase 4 tests")
        else
            -- V-04-01: villager-auto night (or stub path) + SQL assertions.
            local v04_01_game_id = v04.test_v04_01_villager_auto_night(inbox, v04_gm_pid)

            -- V-04-02: tie-break (SKIP — phase-4-real-llm-only).
            v04.test_v04_02_tie_break()

            -- V-04-03: mafia-human night pick injection.
            v04.test_v04_03_mafia_human_night(inbox, v04_gm_pid)

            -- V-04-04: mafia side-chat (SKIP — phase-4-real-llm-only).
            v04.test_v04_04_mafia_side_chat()

            -- V-04-05: partner-dead mafia night (SKIP — phase-4-real-llm-only).
            v04.test_v04_05_partner_dead()

            -- V-04-06: Begin-Day gate (uses V-04-01 game_id if available).
            v04.test_v04_06_begin_day_gate(v04_01_game_id)

            -- V-04-07: scope-leak scan (session-wide errors table check).
            v04.test_v04_07_scope_leak()

            -- V-04-08: Start-New-Game round-trip + intro-gate invariant.
            v04.test_v04_08_start_new_game(inbox, v04_gm_pid)

            -- V-04-09: registry cleanliness after game end.
            v04.test_v04_09_registry_cleanliness(inbox, v04_gm_pid)

            -- V-04-10: WR-06 rounds-table written.
            v04.test_v04_10_rounds_written(inbox, v04_gm_pid)
        end

        logger:info("[test_driver] Phase 4 V-04-XX scenarios complete "
            .. "— inspect log for individual OK|FAIL|SKIP lines")
        logger:info("[test_driver] real-LLM end-to-end: run wippy + browser per 04-06-PLAN.md checkpoint")

        -- ── Phase 5 V-05-XX scenarios ──────────────────────────────────
        -- V-05-01/V-05-02-dev: dev_mode field on game_state_changed.
        -- V-05-02: same-seed determinism (D-SD-02, two-runs-same-seed).
        -- V-05-04: MAFIA_SEED env fallback determinism (D-SD-01, SKIPs if unset).
        -- V-05-05/05b: dev_plugin always-loaded; dev mode sends dev_status frames.
        -- V-05-06/06b/06c/06d/06e: dev_snapshot transport + event_tail ring buffer.
        -- V-05-11/12 require MAFIA_NPC_MODE=real (persona blobs only in real mode).
        -- V-05-13 runs in stub mode (rounds UPSERT is mode-independent).
        logger:info("[test_driver] starting Phase 5 V-05-XX tests")

        local v05_gm_pid = process.registry.lookup("app.game:game_manager")
        if not v05_gm_pid then
            logger:error("[test_driver] V-05-XX: game_manager not found; skipping Phase 5 tests")
        else
            -- V-05-01: dev_mode=true when MAFIA_DEV_MODE=1 (SKIPs if not set).
            v05.test_v05_01_dev_mode_field_true(inbox, v05_gm_pid)

            -- V-05-02 (dev-mode-field-false): dev_mode=false when MAFIA_DEV_MODE unset (SKIPs if =1).
            v05.test_v05_02_dev_mode_field_false(inbox, v05_gm_pid)

            -- V-05-02 (same-seed-determinism): two runs with same seed → identical roster.
            v05.test_v05_02_same_seed_determinism(inbox, v05_gm_pid)

            -- V-05-04: MAFIA_SEED env fallback → games.rng_seed matches env; two runs deterministic.
            v05.test_v05_04_env_seed(inbox, v05_gm_pid)

            -- V-05-11: persona_blob populated for all NPC slots (real mode only).
            v05.test_v05_11_persona_blob_populated(inbox, v05_gm_pid)

            -- V-05-12: persona_blob SHA proxy (length > 200 + distinct; real mode only).
            v05.test_v05_12_persona_blob_sha(inbox, v05_gm_pid)

            -- V-05-05: dev_plugin sends dev_status {enabled=true} on join (dev mode).
            v05.test_v05_05_dev_plugin_dev_status()

            -- V-05-05b: dev_plugin registered in product mode; passive (no events.subscribe).
            v05.test_v05_05b_dev_plugin_product_mode()

            -- V-05-13: rounds.phase UPSERT — phase flips from 'night' to 'day'.
            v05.test_v05_13_rounds_phase_upsert(inbox, v05_gm_pid)

            -- V-05-06: dev_snapshot fires after game.started; roster shape + seed match.
            v05.test_v05_06_dev_snapshot(inbox, v05_gm_pid)

            -- V-05-06b: last_vote populated on roster entries after first vote phase.
            v05.test_v05_06b_last_vote(inbox, v05_gm_pid)

            -- V-05-06c: NPC reply timeout → roster slot marked {unavailable=true}.
            v05.test_v05_06c_unavailable()

            -- V-05-06d: event_tail non-empty after first phase transition.
            v05.test_v05_06d_event_tail(inbox, v05_gm_pid)

            -- V-05-06e: ring buffer cap — burst publishes → event_tail length == 20.
            v05.test_v05_06e_event_tail_cap(inbox, v05_gm_pid)

            -- V-05-10: RSS soak — 10 stub-mode game cycles (D-RR-02..04).
            -- SKIPs unless MAFIA_NPC_MODE=stub. Logs ps-sample instructions
            -- before + after the loop for human RSS audit.
            v05.test_v05_10_rss_soak(inbox, v05_gm_pid)
        end

        logger:info("[test_driver] Phase 5 V-05-XX scenarios complete "
            .. "— inspect log for individual OK|FAIL|SKIP lines")
    end

    -- Stay alive until CANCEL (Phase 1 shape).
    local evs = process.events()
    while true do
        local r = channel.select({ evs:case_receive() })
        if not r.ok then return end
        if r.value and r.value.kind == process.event.CANCEL then return end
    end
end

return { run = run }
