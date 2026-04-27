-- src/game/end_game.lua
-- LOOP-10 (win condition): check_win runs after every elimination (post-night + post-vote).
-- Atomic end-of-game frame non-negotiable (CLAUDE.md Flow Invariant): game_state_changed
-- with phase="ended" MUST carry winner in the same frame as the phase change. The
-- shutdown cascade calls emit_game_state_changed with winner BEFORE game.ended fires.
-- Dead-player UI guard: a dead human sees the end-of-game reveal and can click final
-- gates — no new input surface is created here.
-- SETUP-05: UPDATE games committed BEFORE game.ended publish (Pitfall 3 compliance).
-- Pitfall 3: process.cancel is required — clean parent return does NOT auto-cancel
-- linked children. Each NPC pid gets a 500ms grace.

local logger      = require("logger"):named("end_game")
local time        = require("time")
local sql         = require("sql")
local pe          = require("pe")

-- check_win: D-20 rule.
-- Returns 'villager' if living_mafia == 0,
--         'mafia'    if living_mafia >= living_villagers (parity + majority),
--         nil        otherwise (game continues).
-- Villager-win check runs FIRST because with 0 mafia and 0 villagers (impossible
-- in practice but correct by construction) the villager-win reading is right.
local function check_win(alive, roles)
    local living_mafia = 0
    local living_villagers = 0
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if alive[slot] then
            if roles[slot] == "mafia" then
                living_mafia = living_mafia + 1
            elseif roles[slot] == "villager" then
                living_villagers = living_villagers + 1
            end
        end
    end
    if living_mafia == 0 then return "villager", living_mafia, living_villagers end
    if living_mafia >= living_villagers then return "mafia", living_mafia, living_villagers end
    return nil, living_mafia, living_villagers
end

-- Shutdown cascade: UPDATE games + publish game.ended + cancel all NPC stubs.
-- Pitfall 3: process.cancel is required — clean parent return does NOT
-- auto-cancel linked children. Each stub gets a 500ms grace.
-- SETUP-05: UPDATE games is committed BEFORE game.ended publish.
local function shutdown_cascade(game_id, round, winner, living_mafia, living_villagers, npc_pids)
    local now_ts = time.now():unix()

    local db, db_err = sql.get("app:db")
    if db and not db_err then
        local _, exec_err = db:execute(
            "UPDATE games SET ended_at = ?, winner = ? WHERE id = ?",
            { now_ts, winner, game_id }
        )
        db:release()
        if exec_err then
            logger:error("[orchestrator] games.update failed during shutdown",
                { game_id = game_id, err = tostring(exec_err) })
        end
    else
        logger:error("[orchestrator] sql.get failed during shutdown",
            { game_id = game_id, err = tostring(db_err) })
    end

    pe.publish_event("system", "game.ended", "/" .. game_id, {
        winner = winner,
        final_round = round,
        living_mafia = living_mafia,
        living_villagers = living_villagers,
    })

    -- Cascade cancel all NPC stubs (Pitfall 3).
    for _, pid in pairs(npc_pids) do
        if type(pid) == "string" then
            process.cancel(pid, "500ms")
        end
    end
    logger:info("[orchestrator] shutdown cascade complete", {
        winner = winner, final_round = round,
        living_mafia = living_mafia, living_villagers = living_villagers,
    })
end

-- Phase 4 / D-SCH-02 (closes WR-06): record every phase visit in the rounds table.
-- Schema (0001_initial_schema.lua:35-41): (game_id, round, phase, started_at)
-- with PRIMARY KEY (game_id, round) — only the FIRST phase visit per round is
-- written; subsequent visits are no-ops via INSERT OR IGNORE. WR-06's success
-- criterion ("rounds table is written at least once per round") is met either way.
-- UPSERT: creates row if missing (preserves started_at), always updates phase column.
-- Fire-and-forget — no error return (callers do not inspect result).
local function record_round_phase(game_id, round, phase)
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        logger:warn("[orchestrator] record_round_phase: sql.get failed",
            { err = tostring(db_err) })
        return
    end
    -- Create row if missing; preserve started_at from first write.
    db:execute(
        "INSERT OR IGNORE INTO rounds (game_id, round, phase, started_at) VALUES (?, ?, ?, ?)",
        { game_id, round, phase, time.now():unix() }
    )
    -- Always update phase so day/vote/reveal transitions are reflected.
    db:execute(
        "UPDATE rounds SET phase = ? WHERE game_id = ? AND round = ?",
        { phase, game_id, round }
    )
    db:release()
end

return {
    check_win = check_win,
    shutdown_cascade = shutdown_cascade,
    record_round_phase = record_round_phase,
}
