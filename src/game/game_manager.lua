-- src/game/game_manager.lua
-- Phase 2 Plan 02: game_manager singleton WITH orchestrator spawn.
-- D-01: long-lived process.service at app.game:game_manager.
-- D-05: trap_links=true; on orchestrator crash, mark games.ended/winner='abandoned'
--       via first-signal handled flag (Plan 04 wires EXIT/LINK_DOWN dispatch).
-- D-06: clean-end cascade lands Plan 04.
-- D-12: game.started reply payload = {game_id, player_role, player_slot, roster, partner_slot}.
-- D-17: game_manager is the sole INSERT site for `games` row (orchestrator never writes games;
--       only UPDATEs player_slot/player_role once roles resolved).
-- Note: process.service does NOT auto-register — explicit register below.

local logger = require("logger"):named("game_manager")
local time = require("time")
local channel = require("channel")
local sql = require("sql")
local uuid = require("uuid")
local env = require("env")

-- Phase 2 Plan 04: orchestrator lifecycle dispatch (D-05 abandoned-game policy).
--
-- Pitfall 4 (spawn_linked_monitored fires BOTH EXIT and LINK_DOWN on crash):
-- On the first signal we classify crash-vs-clean, write games row if needed,
-- and flip record.handled=true. The second signal no-ops via the handled guard.

-- Forward declaration: respawn_orchestrator_for_rehydrate is defined later
-- (it depends on spawn_orchestrator), but handle_process_event below needs to
-- call it on EXIT/LINK_DOWN. Lua local-scope resolution requires the binding
-- to exist before reference; the closure in handle_process_event resolves the
-- upvalue at call time, not declaration time, so the forward decl is safe.
local respawn_orchestrator_for_rehydrate

local function find_record_by_pid(state, pid)
    for game_id, record in pairs(state.active_games) do
        if record.orch_pid == pid then return game_id, record end
    end
    return nil, nil
end

-- Mark a game abandoned: UPDATE games SET ended_at, winner='abandoned'.
-- Crash path only — clean end writes games.winner='mafia'|'villager' from
-- the orchestrator's shutdown_cascade.
local function mark_abandoned(game_id)
    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil, "sql.get: " .. tostring(db_err) end
    local _, exec_err = db:execute(
        "UPDATE games SET ended_at = ?, winner = ? WHERE id = ?",
        { time.now():unix(), "abandoned", game_id }
    )
    db:release()
    if exec_err then return nil, "games.update: " .. tostring(exec_err) end
    return true, nil
end

-- Phase 5 D-RH-01: detect mid-game crash by reading games.ended_at.
-- Returns true when the game row exists with started_at not null AND ended_at null.
local function check_game_in_flight(game_id)
    local db, db_err = sql.get("app:db")
    if db_err or not db then return false end
    local rows = db:query(
        "SELECT started_at, ended_at FROM games WHERE id = ?",
        { game_id }
    )
    db:release()
    if not rows or not rows[1] then return false end
    local row = rows[1]
    return row.started_at ~= nil and row.ended_at == nil
end

-- Phase 5 D-RH-01: read rng_seed + player_slot from games row for respawn.
-- player_name is not persisted to games (orchestrator defaults to "You" on
-- rehydration; player_name only matters for chat display + persona partner_name).
-- force_tie is not persisted either; rehydration assumes false (test-only flag).
local function lookup_game_seed_and_slot(game_id)
    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil end
    local rows = db:query(
        "SELECT rng_seed, player_slot FROM games WHERE id = ?",
        { game_id }
    )
    db:release()
    if not rows or not rows[1] then return nil end
    return {
        rng_seed = tonumber(rows[1].rng_seed),
        player_slot = tonumber(rows[1].player_slot) or 1,
    }
end

-- Handle one EXIT or LINK_DOWN. Dual-signal dedupe via record.handled.
local function handle_process_event(state, event)
    if not event then return end
    if event.kind ~= process.event.EXIT and event.kind ~= process.event.LINK_DOWN then
        return
    end
    local game_id, record = find_record_by_pid(state, event.from)
    if not record or not game_id then
        logger:debug("[game_manager] proc_ev from unknown pid",
            { from = tostring(event.from), kind = tostring(event.kind) })
        return
    end
    if record.handled then
        -- Second signal from the double-fire; already processed.
        return
    end

    -- Classify: crash vs. clean-end.
    -- Clean end: orchestrator returned { status = "ended", winner = ... }.
    -- Crash:     LINK_DOWN, OR EXIT with result.error, OR EXIT with missing/wrong status.
    --
    -- Wippy wraps the process return value in `event.result = { value = <return-value> }`.
    -- So the orchestrator's `return { status = "ended", ... }` lands at `event.result.value`.
    -- (Discovered during Phase 2 Plan 05 smoke run; Plan 04 wrote this as `event.result`
    -- directly, which classified every clean-end as a crash → games.winner overwritten
    -- to 'abandoned' right after orchestrator correctly wrote 'mafia' / 'villager'.)
    local was_crash = false
    if event.kind == process.event.LINK_DOWN then
        was_crash = true
    elseif event.kind == process.event.EXIT then
        local wrapped = event.result
        local inner = (type(wrapped) == "table") and wrapped.value or nil
        if type(inner) ~= "table" or inner.status ~= "ended" then
            was_crash = true
        end
        if type(inner) == "table" and inner.error then
            was_crash = true
        end
    end

    if was_crash then
        -- Phase 5 D-RH-01: before marking abandoned, check whether the game
        -- is still in flight. If games.ended_at IS NULL, the orchestrator
        -- crashed mid-game — respawn it instead of abandoning the row.
        if check_game_in_flight(game_id) then
            -- Mark this record handled BEFORE respawning so the second
            -- signal of the dual-signal pair (LINK_DOWN after EXIT) is
            -- swallowed by the dedupe guard against the OLD record.
            record.handled = true
            local new_pid = respawn_orchestrator_for_rehydrate(state, game_id, record)
            if new_pid then
                -- active_games is now keyed by the NEW pid; do NOT clear it.
                return
            end
            -- Respawn failed — fall through to abandon path so the game
            -- row gets marked ended (avoids zombie in-flight rows).
            logger:warn("[game_manager] rehydration respawn failed; marking abandoned",
                { game_id = game_id })
        end
        local ok, err = mark_abandoned(game_id)
        if not ok then
            logger:error("[game_manager] mark_abandoned failed",
                { game_id = game_id, err = tostring(err) })
        else
            logger:info("[game_manager] game abandoned (crash)",
                { game_id = game_id, kind = tostring(event.kind) })
        end
    else
        logger:info("[game_manager] game ended cleanly",
            { game_id = game_id, result = tostring(event.result) })
    end

    record.handled = true
    state.active_games[game_id] = nil
end

-- CANCEL cascade: cancel every live orchestrator when game_manager itself is cancelled.
-- Pitfall 3: explicit cancel required; clean parent return does not auto-cancel children.
local function shutdown_cascade_gm(state)
    local count = 0
    for _, record in pairs(state.active_games) do
        local orch_pid = record.orch_pid
        if type(orch_pid) == "string" then
            process.cancel(orch_pid, "1s")
            count = count + 1
        end
    end
    logger:info("[game_manager] cascade-cancelled orchestrators", { count = count })
end

-- Insert a fresh games row at the moment game.start is received.
local function insert_game_row(game_id, rng_seed, player_slot)
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        return nil, "sql.get: " .. tostring(db_err)
    end
    local _, exec_err = db:execute(
        "INSERT INTO games (id, started_at, rng_seed, player_slot) VALUES (?, ?, ?, ?)",
        { game_id, time.now():unix(), rng_seed, player_slot }
    )
    db:release()
    if exec_err then return nil, "games.insert: " .. tostring(exec_err) end
    return true, nil
end

-- Spawn one orchestrator per game.start.
local function spawn_orchestrator(game_id, rng_seed, player_slot, force_tie, driver_pid, player_name)
    local pid, err = process.spawn_linked_monitored("app.game:orchestrator", "app.processes:host", {
        game_id = game_id,
        rng_seed = rng_seed,
        player_slot = player_slot,
        force_tie = force_tie,
        driver_pid = driver_pid,
        gm_pid = process.pid(),
        player_name = player_name,
    })
    return pid, err
end

-- Phase 5 D-RH-01: respawn orchestrator after a crash when the game is still
-- in flight (games.ended_at IS NULL). Reuses spawn_orchestrator verbatim with
-- the persisted rng_seed; orchestrator INIT detects the existing games row
-- (started_at not null, ended_at null) and routes to rehydrate_state.
-- Returns the new orchestrator pid or nil on failure.
-- Assigned to the forward-declared `respawn_orchestrator_for_rehydrate` upvalue.
respawn_orchestrator_for_rehydrate = function(state, game_id, prev_record)
    local seed_row = lookup_game_seed_and_slot(game_id)
    if not seed_row then
        logger:warn("[game_manager] rehydrate: missing games row for in-flight game",
            { game_id = game_id })
        return nil
    end
    local driver_pid = (prev_record and prev_record.driver_pid) or nil
    local new_pid, spawn_err = spawn_orchestrator(
        game_id, seed_row.rng_seed, seed_row.player_slot,
        false, driver_pid, nil  -- force_tie=false; player_name nil → orchestrator defaults to "You"
    )
    if not new_pid then
        logger:error("[game_manager] rehydrate: orchestrator respawn failed",
            { game_id = game_id, err = tostring(spawn_err) })
        return nil
    end
    -- Reset record.handled=false so the new pid's EXIT/LINK_DOWN won't be
    -- swallowed by the dual-signal dedupe guard. Re-key state.active_games
    -- to the new pid (find_record_by_pid scans on orch_pid).
    state.active_games[game_id] = {
        orch_pid = new_pid,
        driver_pid = driver_pid,
        handled = false,
        started_at = (prev_record and prev_record.started_at) or time.now():unix(),
        rehydrated = true,
    }
    logger:info("[game_manager] orchestrator respawned for rehydration", {
        game_id = game_id,
        orch_pid = tostring(new_pid),
        rng_seed = seed_row.rng_seed,
    })
    return new_pid
end

local function handle_game_start(state, payload)
    payload = payload or {}
    -- D-SD-02: SPA input > MAFIA_SEED env > random fallback.
    -- D-SD-05: structural-determinism only; LLM chat text remains stochastic.
    -- env.get returns (value, metadata_userdata); assign to a local first so
    -- the second return value never reaches tonumber as arg #2.
    local env_seed_str = env.get("MAFIA_SEED")
    local env_seed = env_seed_str and tonumber(env_seed_str) or nil
    local rng_seed = (payload.rng_seed ~= nil and tonumber(payload.rng_seed))
                  or env_seed
                  or math.random(1, 2147483647)
    local player_slot = payload.player_slot or 1
    local force_tie = payload.force_tie == true
    local driver_pid = payload.driver_pid
    local player_name = payload.player_name  -- may be nil; orchestrator defaults

    if type(driver_pid) ~= "string" then
        logger:error("[game_manager] game.start missing driver_pid")
        return
    end

    local game_id = uuid.v4()
    local insert_ok, insert_err = insert_game_row(game_id, rng_seed, player_slot)
    if not insert_ok then
        logger:error("[game_manager] games.insert failed", { err = insert_err })
        process.send(driver_pid, "game.started", {
            error = "games.insert failed: " .. tostring(insert_err),
        })
        return
    end

    local orch_pid, spawn_err = spawn_orchestrator(
        game_id, rng_seed, player_slot, force_tie, driver_pid, player_name)
    if not orch_pid then
        logger:error("[game_manager] orchestrator spawn failed",
            { game_id = game_id, err = tostring(spawn_err) })
        process.send(driver_pid, "game.started", {
            error = "orchestrator spawn failed: " .. tostring(spawn_err),
        })
        return
    end

    -- Record the record BEFORE returning from this handler so orchestrator.ready
    -- (which may arrive immediately) can look it up.
    state.active_games[game_id] = {
        orch_pid = orch_pid,
        driver_pid = driver_pid,
        handled = false,
        started_at = time.now():unix(),
    }
    logger:info("[game_manager] game started", {
        game_id = game_id, orch_pid = tostring(orch_pid), driver_pid = tostring(driver_pid),
    })
end

local function handle_orchestrator_ready(state, payload)
    payload = payload or {}
    local game_id = payload.game_id
    if not game_id then
        logger:warn("[game_manager] orchestrator.ready without game_id",
            { payload = tostring(payload) })
        return
    end
    local record = state.active_games[game_id]
    if not record then
        logger:warn("[game_manager] orchestrator.ready for unknown game",
            { game_id = game_id })
        return
    end
    -- Forward game.started to the driver with the full D-12 payload.
    if type(record.driver_pid) == "string" then
        process.send(record.driver_pid, "game.started", {
            game_id = game_id,
            player_role = payload.player_role,
            player_slot = payload.player_slot,
            roster = payload.roster,
            partner_slot = payload.partner_slot,
        })
    end
    logger:info("[game_manager] game.started forwarded", {
        game_id = game_id, player_role = payload.player_role,
    })
end

local function run(_args)
    local reg_ok, reg_err = process.registry.register("app.game:game_manager")
    if not reg_ok then
        logger:error("[game_manager] registry.register failed",
            { err = tostring(reg_err) })
        return
    end
    process.set_options({ trap_links = true })

    local state = {}
    state.active_games = {}

    local inbox = process.inbox()
    local proc_ev = process.events()

    logger:info("[game_manager] online", { registry = "app.game:game_manager" })

    while true do
        local r = channel.select({ inbox:case_receive(), proc_ev:case_receive() })
        if not r.ok then
            logger:warn("[game_manager] channel.select closed; exiting")
            break
        end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local raw = msg:payload():data()
            local payload = {}
            if type(raw) == "table" then
                for k, v in pairs(raw) do payload[k] = v end
            end

            if topic == "game.start" then
                handle_game_start(state, payload)
            elseif topic == "orchestrator.ready" then
                handle_orchestrator_ready(state, payload)
            else
                logger:debug("[game_manager] unhandled topic",
                    { topic = tostring(topic) })
            end

        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                logger:info("[game_manager] CANCEL received; cascading and exiting")
                shutdown_cascade_gm(state)
                break
            end
            -- EXIT + LINK_DOWN from orchestrator children (spawn_linked_monitored
            -- fires BOTH on crash — handle_process_event dedupes via record.handled).
            handle_process_event(state, event)
        end
    end

    return { status = "shutdown" }
end

return { run = run }
