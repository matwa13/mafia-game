-- src/game/orchestrator.lua
-- Phase 2 Plan 02: orchestrator INIT phase.
-- D-01/D-02: dynamically spawned by game_manager via spawn_linked_monitored.
-- D-03: shuffle 2M+4V roles; INSERT 6 players rows (5 NPC slots 2..6 + 1 player); reveal partner to mafia.
-- D-04: args carry rng_seed, player_slot, force_tie (flows to vote.prompt Plan 04).
-- D-12: game.started reply shape to driver.
-- D-14: helpers stay inline until >80 lines (Phase 2 scope).
-- D-20: orchestrator sole writer of messages (Plans 03/04 enforce).
-- D-22: MAFIA_DEV_MODE -> state.day_duration / state.pacing.
-- Plan 02 scope: INIT only. Plan 03 adds Night/Day, Plan 04 adds Vote/Win/Shutdown.

local logger = require("logger"):named("orchestrator")
local time = require("time")
local channel = require("channel")
local sql = require("sql")
local uuid = require("uuid")
local env = require("env")
-- pe is injected as an import alias; not used in Plan 02 but reserved for Plans 03/04.

local DAY_DURATION_PROD = "60s"
local DAY_DURATION_DEV  = "3s"
local PACING_PROD_MS    = 500
local PACING_DEV_MS     = 100

local function dev_mode()
    return env.get("MAFIA_DEV_MODE") == "1"
end

-- Deterministic Fisher-Yates shuffle of the canonical 2M+4V role pool across 6 slots.
-- D-02 (amended 2026-04-22): 6 participants = 1 human (slot 1) + 5 NPC stubs (slots 2..6).
-- Human participates in the shuffle per ROLE-02.
local function shuffle_roles(rng_seed)
    math.randomseed(rng_seed)
    local roles = {}
    roles[1] = "mafia"
    roles[2] = "mafia"
    roles[3] = "villager"
    roles[4] = "villager"
    roles[5] = "villager"
    roles[6] = "villager"
    for i = 6, 2, -1 do
        local j = math.random(i)
        roles[i], roles[j] = roles[j], roles[i]
    end
    return roles  -- roles[slot] = "mafia"|"villager" for slot in 1..6
end

local function compute_partner_slot(roles, target_slot)
    -- For a mafia at target_slot, return the OTHER mafia's slot.
    if roles[target_slot] ~= "mafia" then return nil end
    for s = 1, 6 do
        if roles[s] == "mafia" and s ~= target_slot then return s end
    end
    return nil
end

-- INSERT 6 players rows (canonical participant count per D-02) + UPDATE games.player_slot + games.player_role.
-- Uses db:begin() tx for atomicity (Pattern 3).
local function persist_roles(game_id, roles, player_slot)
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        return nil, "sql.get: " .. tostring(db_err)
    end
    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return nil, "begin: " .. tostring(tx_err)
    end
    local ok, err = pcall(function()
        for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
            local display_name = string.format("slot-%d", slot)
            local persona_blob = ""  -- Phase 4 fills this; Phase 2 is stub
            local role = roles[slot]
            local _, e = tx:execute(
                "INSERT INTO players (game_id, slot, display_name, persona_blob, role, alive) VALUES (?, ?, ?, ?, ?, 1)",
                { game_id, slot, display_name, persona_blob, role }
            )
            assert(not e, "players.insert slot=" .. slot .. ": " .. tostring(e))
        end
        local player_role = roles[player_slot]
        local _, e2 = tx:execute(
            "UPDATE games SET player_slot = ?, player_role = ? WHERE id = ?",
            { player_slot, player_role, game_id }
        )
        assert(not e2, "games.update: " .. tostring(e2))
    end)
    if not ok then
        tx:rollback()
        db:release()
        return nil, tostring(err)
    end
    local _, commit_err = tx:commit()
    db:release()
    if commit_err then return nil, "commit: " .. tostring(commit_err) end
    return true
end

-- Spawn one npc_stub per non-player slot. D-02: human is slot 1; NPC stubs occupy slots 2..6.
local function spawn_stubs(game_id, roles, player_slot)
    local npc_pids = {}
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if slot ~= player_slot then
            local role = roles[slot]
            local partner = compute_partner_slot(roles, slot)
            local pid, err = process.spawn_linked_monitored("app.npc:npc_stub", "app.processes:host", {
                game_id = game_id,
                slot = slot,
                role = role,
                mafia_partner_slot = partner,
                parent_pid = process.pid(),
            })
            if not pid then
                return nil, "spawn slot=" .. slot .. ": " .. tostring(err)
            end
            npc_pids[slot] = pid
        end
    end
    return npc_pids, nil
end

-- Gather N npc.ready acks with a single deadline (Pattern 1 + Research Q1 3s cap).
local function gather_readiness(inbox, expected_count, cap)
    local received = {}
    local deadline = time.after(cap)
    while true do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel ~= inbox then
            return received, "timeout after " .. cap
        end
        local topic_ok, topic = pcall(function() return r.value:topic() end)
        if topic_ok and topic == "npc.ready" then
            local raw = r.value:payload():data()
            local slot = (type(raw) == "table" and raw.slot) or nil
            if slot then received[slot] = true end
            local count = 0
            for _ in pairs(received) do count = count + 1 end
            if count >= expected_count then return received, nil end
        end
    end
end

local function build_roster(_roles)
    local roster = {}
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        roster[slot] = { slot = slot, display_name = string.format("slot-%d", slot) }
    end
    return roster
end

local function run(args)
    args = args or {}
    local game_id = args.game_id
    local rng_seed = args.rng_seed
    local player_slot = args.player_slot or 1
    local force_tie = args.force_tie == true
    local driver_pid = args.driver_pid
    local gm_pid = args.gm_pid

    if not (game_id and rng_seed and gm_pid) then
        logger:error("[orchestrator] missing required args", { args = tostring(args) })
        return
    end

    -- 1. Register by well-known name (D-02).
    local reg_ok, reg_err = process.registry.register("game:" .. game_id)
    if not reg_ok then
        logger:error("[orchestrator] registry.register failed",
            { game_id = game_id, err = tostring(reg_err) })
        return
    end

    -- 2. trap_links so stub crashes land on our events channel (Plan 04 handles them).
    process.set_options({ trap_links = true })

    -- 3. Timing mode (D-22).
    local dev = dev_mode()
    local state = {
        game_id = game_id,
        rng_seed = rng_seed,
        player_slot = player_slot,
        force_tie = force_tie,
        driver_pid = driver_pid,
        gm_pid = gm_pid,
        day_duration = dev and DAY_DURATION_DEV or DAY_DURATION_PROD,
        pacing_ms = dev and PACING_DEV_MS or PACING_PROD_MS,
        round = 0,
        roles = nil,
        roster = nil,
        npc_pids = {},
        alive = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true },  -- 6 slots (D-02)
    }
    logger:info("[orchestrator] INIT", {
        game_id = game_id, dev_mode = dev,
        day_duration = state.day_duration, pacing_ms = state.pacing_ms,
    })

    -- 4. Shuffle roles + persist players + update games.
    state.roles = shuffle_roles(rng_seed)
    local persist_ok, persist_err = persist_roles(game_id, state.roles, player_slot)
    if not persist_ok then
        logger:error("[orchestrator] persist_roles failed", { err = tostring(persist_err) })
        return
    end
    state.roster = build_roster(state.roles)

    -- 5. Spawn 5 stubs (slots 2..6 per D-02).
    local npc_pids, spawn_err = spawn_stubs(game_id, state.roles, player_slot)
    if not npc_pids then
        logger:error("[orchestrator] spawn_stubs failed", { err = tostring(spawn_err) })
        return
    end
    state.npc_pids = npc_pids

    -- 6. Gather 5 readiness acks with 3s deadline (Pattern 1, Research Q1).
    local inbox = process.inbox()
    local received, gather_err = gather_readiness(inbox, 5, "3s")  -- 5 NPC stubs at slots 2..6 (D-02)
    if gather_err then
        logger:error("[orchestrator] readiness gather timeout",
            { received = tostring(received), err = gather_err })
        return
    end
    logger:info("[orchestrator] all stubs ready", { game_id = game_id })

    -- 7. Send orchestrator.ready -> game_manager with full payload for game.started reply.
    local player_role = state.roles[player_slot]
    local partner_slot = compute_partner_slot(state.roles, player_slot)  -- nil if player is villager
    process.send(gm_pid, "orchestrator.ready", {
        game_id = game_id,
        player_role = player_role,
        player_slot = player_slot,
        roster = state.roster,
        partner_slot = partner_slot,  -- nil unless mafia (ROLE-03/ROLE-04)
    })

    -- 8. Placeholder main loop (Plans 03/04 replace with full FSM).
    --    Plan 02 scope: await CANCEL. Our children are linked so we MUST stay alive
    --    until CANCEL; otherwise cancel-cascade kills stubs before V-02-02 observes post-INIT state.
    local proc_ev = process.events()
    while true do
        local r = channel.select({ inbox:case_receive(), proc_ev:case_receive() })
        if not r.ok then break end
        if r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                logger:info("[orchestrator] CANCEL; exiting (Plan 04 adds cascade)")
                break
            end
            -- Plan 04 handles EXIT/LINK_DOWN
        elseif r.channel == inbox then
            -- Plan 03/04 dispatch chat.submit, vote.cast, etc.
            local topic_ok, topic = pcall(function() return r.value:topic() end)
            logger:debug("[orchestrator] inbox (Plan 02 placeholder)",
                { topic = topic_ok and tostring(topic) or "<?>" })
        end
    end

    return { status = "shutdown", game_id = game_id }
end

return { run = run }
