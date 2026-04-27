-- src/game/intro.lua
-- Intro gate before Night 1 non-negotiable (CLAUDE.md Flow Invariant):
-- orchestrator emits game_state_changed(phase="intro") with full roster and blocks
-- on player.start_game. No night kill, no LLM calls, no chat until gate exits.
-- Phase 3 polish lineage: see .planning/phases/03-*/03-POLISH-LOG.md.
-- SETUP-04 start-new-game teardown must return to this gate — not jump into Night 1.
-- No time.after() here: intro gate is user-driven, not wall-clock driven.

local logger      = require("logger"):named("intro")
local channel     = require("channel")
local pe          = require("pe")
local game_state  = require("game_state")
local dev_telemetry = require("dev_telemetry")

-- Convenience aliases matching orchestrator.lua convention.
local append_dev_event        = dev_telemetry.append_dev_event
local emit_game_state_changed = game_state.emit_game_state_changed

-- run_intro: emit phase="intro" game_state_changed with full roster; block on
-- player.start_game. The state table carries game_id, alive, roles, slot_persona,
-- roster_names, player_slot, and the dev_event_tail ring buffer. inbox is the
-- orchestrator's process inbox (passed by caller to avoid a second process.inbox() call).
--
-- Returns nil (sequence step — caller continues into FSM loop after return).
local function run_intro(state, player_slot, inbox)
    -- Intro gate: emit phase="intro" with full roster and block until the
    -- player explicitly starts the game. No night kill, no LLM calls, no
    -- chat until the gate exits via player.start_game.
    state.phase = "intro"
    emit_game_state_changed(state.game_id, state.alive, state.roles, state.slot_persona,
        state.roster_names, player_slot, "intro", 0, false)
    append_dev_event(state, "system", "game_state_changed", "/" .. state.game_id)

    logger:info("[orchestrator] intro gate: waiting for player.start_game",
        { game_id = state.game_id })
    while true do
        local r = channel.select({ inbox:case_receive() })
        if not r.ok then
            logger:warn("[orchestrator] inbox closed during intro gate")
            break
        end
        local msg = r.value
        if msg and msg:topic() == "player.start_game" then break end
        -- Drop every other topic (stale chat/vote, unknown commands).
    end
end

return {
    run_intro = run_intro,
}
