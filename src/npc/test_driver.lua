-- src/npc/test_driver.lua
-- Phase 1 test-driver shell. Supervised process that boot-waits the
-- npc:test fixture and then dispatches the V-01-XX scenario library
-- (app.npc.tests:v01_setup) in sequence. Each scenario emits exactly
--     [TEST] <name> OK | FAIL: <reason> | SKIP: <reason>
-- per Phase 1 D-21. Test bodies live in src/npc/tests/v01_setup.lua;
-- shared harness helpers live in src/lib/test_harness.lua.
--
-- Phase 6 cut 4 (T-04): bodies extracted to v01_setup.lua per
-- 06-PATTERNS.md Pattern B (process.lua run-shell + import dispatch).
-- Tests (one-to-one with 01-VALIDATION.md V-01-01..V-01-10):
--   1. npc-reachable         — ping/pong over inbox reverse channel
--   2. npc-restart           — terminate + re-lookup returns a NEW pid
--   3. chat-success          — speak → npc_message_done with non-empty text   (SKIP if no ANTHROPIC_API_KEY)
--   4. chat-error-path       — force_error RATE_LIMIT → npc_turn_skipped_ack + 3 error rows
--   5. vote-abstain          — force_error TIMEOUT → vote_done{target=nil} + ≥1 error row
--   6. vote-success          — real vote returns integer target + reasoning   (SKIP if no ANTHROPIC_API_KEY)
--   7. villager-no-mafia     — export_event_log shows zero mafia-scoped events
--   8. scope-leak-panic      — inject_event(mafia) + speak → D-11 panic → supervisor restart
--   9. persona-drift-panic   — mutate_persona + speak → D-15 panic → supervisor restart
--  10. events-send-auditable — grep audit: `events.send` occurs only in src/lib/events.lua

local logger  = require("logger"):named("test_driver")
local channel = require("channel")
local v01     = require("v01")

-- ──────────────────────────────────────────────────────────────────
-- Main run(args) — boot-wait, sequential test matrix, then stay-alive
-- on CANCEL. Ordering of the three forced-restart tests
-- (V-01-02 → V-01-08 → V-01-09) matches the restart-budget headroom
-- contract: npc_test_service has max_attempts: 5, leaving ≥2 headroom
-- after this driver completes.
-- ──────────────────────────────────────────────────────────────────
local function run(_args)
    local inbox = process.inbox()

    logger:info("[test_driver] starting Phase 1 tests")

    -- Initial boot-wait: npc_test_service auto_start + initial_delay 2s.
    -- Both services start concurrently at lifecycle level 1; the driver's
    -- first lookup can race npc_test's registry.register. Give a generous
    -- 5s budget so the racing-boot case resolves before V-01-01 runs.
    v01.lookup_npc(50, "100ms")

    v01.test_npc_reachable(inbox)
    v01.test_npc_restart()
    v01.test_chat_success(inbox)
    v01.test_chat_error_path(inbox)
    v01.test_vote_abstain(inbox)
    v01.test_vote_success(inbox)
    v01.test_villager_no_mafia(inbox)
    v01.test_scope_leak_panic()
    v01.test_persona_drift_panic()
    v01.test_events_send_auditable()

    logger:info("[test_driver] all Phase 1 tests complete")

    -- Stay alive until CANCEL so registry state is stable for follow-up.
    -- EXACT copy from src/probes/probe.lua lines 265-275.
    local evs = process.events()
    while true do
        local r = channel.select({ evs:case_receive() })
        if r.ok and r.value and r.value.kind == process.event.CANCEL then
            return
        end
        if not r.ok then
            return
        end
    end
end

return { run = run }
