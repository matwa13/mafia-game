-- src/game/orchestrator.lua
-- Phase 2 Plan 02: orchestrator INIT phase.
-- D-01/D-02: dynamically spawned by game_manager via spawn_linked_monitored.
-- D-03: shuffle 2M+4V roles; INSERT 6 players rows (5 NPC slots 2..6 + 1 player); reveal partner to mafia.
-- D-04: args carry rng_seed, player_slot, force_tie (flows to vote.prompt Plan 04).
-- D-12: game.started reply shape to driver.
-- D-14: helpers stay inline until >80 lines (Phase 2 scope).
-- D-20: orchestrator sole writer of messages (Plans 03/04 enforce).
-- Plan 02 scope: INIT only. Plan 03 adds Night/Day, Plan 04 adds Vote/Win/Shutdown.

local logger = require("logger"):named("orchestrator")
local time = require("time")
local channel = require("channel")
local sql = require("sql")
local uuid = require("uuid")
local env = require("env")
local pe = require("pe")  -- Phase 1 D-11 precedent: yaml imports pe -> app.lib:events
local det_rng = require("det_rng")  -- D-SD-05: same-seed-same-setup determinism
local sampler      = require("sampler")
local persona_pool = require("persona_pool")
local persona      = require("persona")
local chat         = require("chat")         -- D-02 / D-15: SOLE writer of chat.line events (cut 6)
local game_state   = require("game_state")   -- frame builder: build_gsc_roster + emit_game_state_changed* (cut 6)
local dev_telemetry = require("dev_telemetry") -- dev mode flag + ring buffer + dev_snapshot (cut 6)
local night        = require("night")        -- LOOP-02/03: night phase handlers (cut 7)
local day          = require("day")          -- LOOP-04/05: day discussion (cut 7)
local vote         = require("vote")         -- LOOP-08/09: vote phase handlers (cut 7)
local end_game     = require("end_game")     -- LOOP-10: win check + shutdown cascade (cut 7)
local intro        = require("intro")        -- intro gate before Night 1 (cut 7)

-- Convenience aliases so existing FSM code is unchanged.
local dev_mode                    = dev_telemetry.dev_mode
local append_dev_event            = dev_telemetry.append_dev_event
local emit_dev_snapshot           = dev_telemetry.emit_dev_snapshot
local emit_game_state_changed     = game_state.emit_game_state_changed
local emit_game_state_changed_elim = game_state.emit_game_state_changed_elim
local compute_partner_slot        = game_state.compute_partner_slot

-- MAFIA_NPC_MODE routing (D-08): "real" (default) or "stub". Phase 2 test_driver
-- sets this to "stub" via .env to keep the Phase 2 V-02-XX harness green.
local function npc_mode()
    local m = env.get("MAFIA_NPC_MODE")
    if m == "stub" or m == "real" then return m end
    return "real"
end

-- Deterministic Fisher-Yates shuffle of the canonical 2M+4V role pool across 6 slots.
-- D-02 (amended 2026-04-22): 6 participants = 1 human (slot 1) + 5 NPC stubs (slots 2..6).
-- Human participates in the shuffle per ROLE-02.
-- D-SD-05 (amended): use det_rng instead of math.randomseed/math.random. The
-- Wippy Lua runtime does not honour math.randomseed across orchestrator
-- processes — same seed produces different shuffle results in practice
-- (verified empirically). det_rng is a self-contained LCG that gives the
-- intended same-seed-same-setup contract.
local function shuffle_roles(rng_seed)
    local rng = det_rng.new(rng_seed)
    local roles = {}
    roles[1] = "mafia"
    roles[2] = "mafia"
    roles[3] = "villager"
    roles[4] = "villager"
    roles[5] = "villager"
    roles[6] = "villager"
    for i = 6, 2, -1 do
        local j = rng:int(i)
        roles[i], roles[j] = roles[j], roles[i]
    end
    return roles  -- roles[slot] = "mafia"|"villager" for slot in 1..6
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

-- Persist rendered persona blobs to players.persona_blob (D-RH-03 precondition).
-- Replicates spawn_npcs partner_name resolution byte-for-byte so SHA256 matches on respawn.
-- player_name is state.player_name (used when the player is a mafia partner).
local function persist_persona_blobs(game_id, slot_persona, roles, player_slot, roster_names_arr, player_name)
    local db, err = sql.get("app:db")
    if err or not db then return nil, "sql.get: " .. tostring(err) end
    for slot = 1, 6 do
        if slot ~= player_slot and slot_persona[slot] then
            local p = slot_persona[slot]
            -- replicate spawn_npcs partner_name logic exactly
            local partner_name = nil
            if roles[slot] == "mafia" then
                for s2 = 1, 6 do
                    if s2 ~= slot and roles[s2] == "mafia" then
                        if s2 == player_slot then
                            partner_name = (roster_names_arr and roster_names_arr[player_slot]) or player_name or "You"
                        elseif slot_persona[s2] then
                            partner_name = slot_persona[s2].name
                        end
                        break
                    end
                end
            end
            local persona_args = {
                archetype            = p.archetype,
                name                 = p.name,
                voice_quirk          = p.voice_quirk,
                canonical_utterances = p.canonical_utterances or {},
                role                 = roles[slot],
                partner_name         = partner_name,
                roster_names         = roster_names_arr or {},
                rules_text           = persona.RULES,
            }
            local blob = tostring(persona.render_stable_block(persona_args))
            local _, e = db:execute(
                "UPDATE players SET persona_blob = ? WHERE game_id = ? AND slot = ?",
                { blob, game_id, slot }
            )
            if e then db:release(); return nil, "update slot=" .. slot .. ": " .. tostring(e) end
        end
    end
    db:release()
    return true, nil
end

-- Renamed: spawn_npcs. Under MAFIA_NPC_MODE=stub, behaves like Phase 2.
-- Under MAFIA_NPC_MODE=real, spawns app.npc:npc with full persona args.
local function spawn_npcs(game_id, roles, player_slot, slot_persona, roster_names, name_to_slot)
    local npc_pids = {}
    local mode = npc_mode()
    local target = (mode == "real") and "app.npc:npc" or "app.npc:npc_stub"
    logger:info("[orchestrator] spawn_npcs", { game_id = game_id, mode = mode, target = target })
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if slot ~= player_slot then
            -- Compute partner info if this slot is mafia.
            local partner_slot = nil
            local partner_name = nil
            if roles[slot] == "mafia" then
                for s = 1, 6 do
                    if s ~= slot and roles[s] == "mafia" then
                        partner_slot = s
                        if s ~= player_slot and slot_persona[s] then
                            partner_name = slot_persona[s].name
                        elseif s == player_slot then
                            -- Use the player's real name from roster_names
                            -- (populated at INIT). Fallback to "You" for
                            -- legacy callers that don't populate it.
                            partner_name = (roster_names and roster_names[player_slot]) or "You"
                        end
                        break
                    end
                end
            end
            local spawn_args = {
                game_id = game_id, slot = slot, role = roles[slot],
                mafia_partner_slot = partner_slot,
                mafia_partner_name = partner_name,
                parent_pid = process.pid(),
            }
            -- Phase 3 real-NPC additions (ignored by stub).
            if mode == "real" and slot_persona[slot] then
                spawn_args.name = slot_persona[slot].name
                spawn_args.archetype = slot_persona[slot].archetype
                spawn_args.archetype_id = slot_persona[slot].archetype_id
                spawn_args.voice_quirk = slot_persona[slot].voice_quirk
                spawn_args.canonical_utterances = slot_persona[slot].canonical_utterances
                spawn_args.roster_names = roster_names
                spawn_args.name_to_slot = name_to_slot
            end
            local pid, err = process.spawn_linked_monitored(target, "app.processes:host", spawn_args)
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

-- Night phase functions (pick_night_victim, pick_night_actor, run_night_stub,
-- run_night_villager_auto, run_night_mafia_human) extracted to src/game/night.lua (cut 7).
-- Day phase functions (speaking_order, run_day_discussion, run_day_discussion_streaming)
-- extracted to src/game/day.lua (cut 7).


-- Vote phase functions (alive_slots_array, gather_votes, persist_votes, tally_votes,
-- persist_lynch, run_vote_round, run_vote_round_llm) extracted to src/game/vote.lua (cut 7).
-- End-game functions (check_win, shutdown_cascade, record_round_phase) extracted to
-- src/game/end_game.lua (cut 7).

local function run(args)
    args = args or {}
    local game_id = args.game_id
    local rng_seed = args.rng_seed
    local player_slot = args.player_slot or 1
    local force_tie = args.force_tie == true
    local driver_pid = args.driver_pid
    local gm_pid = args.gm_pid
    -- Player-supplied display name. Flows into roster_names[player_slot] so
    -- NPCs see the real name in their event log (visible_context) and the
    -- SPA renders it in roster chips and chat bubbles. Defaults to "You" so
    -- legacy callers (test_driver etc.) still work without plumbing.
    local player_name = args.player_name
    if type(player_name) ~= "string" or player_name == "" then
        player_name = "You"
    end

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

    -- 3. Timing mode (D-22). Stale DAY_DURATION_*/PACING_*_MS constants deleted (D-DEV-03).
    local dev = dev_mode()
    local state = {
        game_id = game_id,
        rng_seed = rng_seed,
        player_slot = player_slot,
        force_tie = force_tie,
        driver_pid = driver_pid,
        gm_pid = gm_pid,
        round = 0,
        phase = "init",
        roles = nil,
        roster = nil,
        npc_pids = {},
        alive = {},  -- populated below to avoid literal-tuple type narrowing
        chat_seq = {},  -- per-round message counter; written by commit_chat_line
        -- D-DP-10: ring buffer for dev snapshot event_tail.
        dev_event_tail = {},
        dev_event_tail_idx = 0,
    }
    -- D-02: 6 slots, all initially alive. Assigned outside the constructor so the
    -- lint infers `{[integer]: boolean}` rather than a fixed 6-element true-tuple.
    for slot = 1, 6 do state.alive[slot] = true end
    logger:info("[orchestrator] INIT", {
        game_id = game_id, dev_mode = dev,
        -- Determinism trace (D-SD-05): emit seed type+value so two runs
        -- with the "same" seed can be compared in logs to verify the
        -- structural-determinism contract before any RNG is consumed.
        rng_seed = rng_seed,
        rng_seed_type = type(rng_seed),
    })

    -- 4. Shuffle roles + persist players + update games.
    state.roles = shuffle_roles(rng_seed)
    logger:info("[orchestrator] roles shuffled", {
        game_id = game_id,
        rng_seed = rng_seed,
        roles = state.roles,
    })
    local persist_ok, persist_err = persist_roles(game_id, state.roles, player_slot)
    if not persist_ok then
        logger:error("[orchestrator] persist_roles failed", { err = tostring(persist_err) })
        return
    end
    state.roster = build_roster(state.roles)

    -- 4b. Phase 3: sample personas under real mode; stub names under stub mode.
    local slot_persona = {}
    local roster_names = {}
    local name_to_slot = {}
    if npc_mode() == "real" then
        local personas = sampler.sample_personas(
            persona_pool.ARCHETYPES, persona_pool.NAMES, 5, rng_seed)
        local idx = 0
        for slot = 1, 6 do
            if slot == player_slot then
                roster_names[slot] = player_name
                name_to_slot[player_name] = slot
            else
                idx = idx + 1
                slot_persona[slot] = personas[idx]
                roster_names[slot] = personas[idx].name
                name_to_slot[personas[idx].name] = slot
            end
        end
        logger:info("[orchestrator] personas sampled", {
            game_id = game_id,
            rng_seed = rng_seed,
            roster = roster_names,
        })
    else
        -- Stub mode: synthesize minimal names for audit/logs.
        for slot = 1, 6 do
            if slot == player_slot then
                roster_names[slot] = player_name
                name_to_slot[player_name] = slot
            else
                roster_names[slot] = "stub-" .. tostring(slot)
                name_to_slot[roster_names[slot]] = slot
            end
        end
    end
    state.slot_persona = slot_persona
    state.roster_names = roster_names
    state.name_to_slot = name_to_slot

    -- 4c. Persist persona blobs (D-RH-03 precondition; must run before spawn_npcs
    -- so rehydration on NPC respawn can read the blob from SQL).
    -- Only meaningful in real mode (stub mode has no persona args to render).
    if npc_mode() == "real" then
        local blob_ok, blob_err = persist_persona_blobs(
            game_id, slot_persona, state.roles, player_slot, roster_names, player_name)
        if not blob_ok then
            logger:error("[orchestrator] persist_persona_blobs failed",
                { err = tostring(blob_err) })
            return
        end
        logger:info("[orchestrator] persona blobs persisted", { game_id = game_id })
    end

    -- 5. Spawn NPCs (routes to npc or npc_stub based on MAFIA_NPC_MODE).
    local npc_pids, spawn_err = spawn_npcs(game_id, state.roles, player_slot,
        slot_persona, roster_names, name_to_slot)
    if not npc_pids then
        logger:error("[orchestrator] spawn_npcs failed", { err = tostring(spawn_err) })
        return
    end
    state.npc_pids = npc_pids

    -- 6. Gather 5 readiness acks with 3s deadline (Pattern 1, Research Q1).
    local inbox = process.inbox()
    local received, gather_err = gather_readiness(inbox, 5, "3s")  -- 5 NPCs at slots 2..6 (D-02)
    if gather_err then
        logger:error("[orchestrator] readiness gather timeout",
            { received = tostring(received), err = gather_err })
        return
    end
    logger:info("[orchestrator] all NPCs ready", { game_id = game_id })

    -- 7. Send orchestrator.ready -> game_manager with full payload for game.started reply.
    local player_role = state.roles[player_slot]
    local partner_slot = compute_partner_slot(state.roles, player_slot)  -- nil if player is villager
    process.send(gm_pid, "orchestrator.ready", {
        game_id = game_id,
        player_role = player_role,
        player_slot = player_slot,
        roster = state.roster,
        roster_names = roster_names,
        partner_slot = partner_slot,  -- nil unless mafia (ROLE-03/ROLE-04)
    })

    -- Intro gate: emit phase="intro" + block on player.start_game (cut 7 → intro.lua).
    intro.run_intro(state, player_slot, inbox)

    -- 8. Post-INIT FSM loop (Plan 04).
    --    Night -> check_win -> Day -> Vote -> check_win -> loop | shutdown.
    --    LOOP-01 end-to-end. On non-nil winner: shutdown cascade + return.
    local winner = nil
    local living_mafia, living_villagers
    while not winner do
        state.round = (state.round or 0) + 1

        -- D-SCH-02 / WR-06: record phase visit. PK is (game_id, round); only the
        -- first phase per round actually writes — that's still enough to close WR-06.
        end_game.record_round_phase(game_id, state.round, "night")

        state.phase = "night"
        emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
            state.roster_names, player_slot, "night", state.round, false)
        append_dev_event(state, "system", "game_state_changed", "/" .. game_id)
        -- D-DP-03 (gap fix): emit dev_snapshot at night start so the DevDrawer
        -- has roster + telemetry on first paint. Without this the drawer mounts
        -- empty (npc undefined for every card) until end-of-night, since the
        -- existing emit_dev_snapshot call is at the begin-day gate (line ~2210).
        emit_dev_snapshot(state)

        -- Phase 4 LOOP-02: branch on player role at night.
        -- Stub path (used by test_driver V-02-XX harness): keep run_night_stub.
        -- Real-LLM path: villager → run_night_villager_auto, mafia → run_night_mafia_human.
        local ok_night, night_result
        if npc_mode() == "real" then
            if state.roles[player_slot] == "villager" then
                ok_night, night_result = night.run_night_villager_auto(
                    game_id, state.round, state.alive, state.roles, state.npc_pids,
                    state.roster_names)
            else
                ok_night, night_result = night.run_night_mafia_human(
                    game_id, state.round, state.alive, state.roles, player_slot,
                    state.npc_pids, state.chat_seq, inbox, state.roster_names)
            end
        else
            ok_night, night_result = night.run_night_stub(
                game_id, state.round, rng_seed, state.alive, state.roles, state.npc_pids)
        end
        if not ok_night then
            logger:error("[orchestrator] night helper failed",
                { mode = npc_mode(), err = tostring(night_result) })
            break
        end

        -- D-NU-03: 3s min-dwell so the player feels the night pass even if the
        -- LLM/picker returned fast. Drain inbox during the dwell window
        -- (same pattern as run_day_discussion's 500ms drain).
        local night_dwell = time.after("3s")
        while true do
            local r = channel.select({ inbox:case_receive(), night_dwell:case_receive() })
            if not r.ok or r.channel == night_dwell then break end
            -- discard messages during dwell
        end

        -- D-NU-02: explicit Begin-Day gate — orchestrator publishes night.ready_for_day,
        -- waits for player.advance_phase. Verbatim mirror of the post-vote gate below.
        local pre_gate_drain = time.after("50ms")
        while true do
            local r = channel.select({ inbox:case_receive(), pre_gate_drain:case_receive() })
            if not r.ok or r.channel == pre_gate_drain then break end
        end

        pe.publish_event("system", "night.ready_for_day", "/" .. game_id, {
            round = state.round,
        })
        append_dev_event(state, "system", "night.ready_for_day", "/" .. game_id)
        emit_dev_snapshot(state)
        logger:info("[orchestrator] night resolved, awaiting begin-day",
            { round = state.round })
        while true do
            local r = channel.select({ inbox:case_receive() })
            if not r.ok then break end
            local msg = r.value
            if msg and msg:topic() == "player.advance_phase" then
                local raw = (msg:payload() and msg:payload():data()) or {}
                if tonumber(raw.round) == state.round then break end
            end
        end

        -- LOOP-10: win check after the night elimination.
        winner, living_mafia, living_villagers = end_game.check_win(state.alive, state.roles)
        if winner then break end

        -- D-SCH-02: record day phase visit (no-op due to PK if night already wrote).
        end_game.record_round_phase(game_id, state.round, "day")

        -- Emit game_state_changed WITH last_eliminated so the SPA can name the
        -- victim ("ALICE WAS ELIMINATED"). Without this, the store falls back
        -- to String(victim_slot) and renders "2 WAS ELIMINATED".
        -- night_result is the victim_slot returned by run_night_stub.
        state.phase = "day"
        local night_victim_slot = night_result
        if type(night_victim_slot) == "number" and state.roster_names then
            local vname = state.roster_names[night_victim_slot] or ("slot-" .. night_victim_slot)
            -- Night victims are always villagers (see pick_night_victim); the
            -- fallback satisfies the non-nil string contract of emit_game_state_changed_elim.
            local vrole = (state.roles and state.roles[night_victim_slot]) or "villager"
            emit_game_state_changed_elim(game_id, state.alive, state.roles, state.slot_persona,
                state.roster_names, player_slot, "day", state.round,
                night_victim_slot, vname, vrole, "night",
                false) -- chat_locked=false: day chat opens now
        else
            emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
                state.roster_names, player_slot, "day", state.round, false)
        end
        append_dev_event(state, "system", "game_state_changed", "/" .. game_id)

        local ok_day, day_err
        if npc_mode() == "real" then
            ok_day, day_err = day.run_day_discussion_streaming(
                game_id, state.round, state.alive, state.player_slot, state.npc_pids,
                dev, state.chat_seq, inbox,
                state.rng_seed, state.roles, state.slot_persona, state.roster_names,
                state)
        else
            ok_day, day_err = day.run_day_discussion(
                game_id, state.round, state.alive, state.player_slot, state.npc_pids,
                dev and "3s" or "60s", dev and 100 or 500, dev, state.chat_seq, inbox)
        end
        if not ok_day then
            logger:error("[orchestrator] run_day_discussion failed",
                { err = tostring(day_err) })
            break
        end

        -- D-SCH-02: record vote phase visit (no-op due to PK if earlier phase wrote).
        end_game.record_round_phase(game_id, state.round, "vote")

        state.phase = "vote"
        emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
            state.roster_names, player_slot, "vote", state.round, false)
        append_dev_event(state, "system", "game_state_changed", "/" .. game_id)
        emit_dev_snapshot(state)

        local ok_vote, vote_err
        if npc_mode() == "real" then
            ok_vote, vote_err = vote.run_vote_round_llm(
                game_id, state.round, state.alive, state.roles,
                state.player_slot, state.npc_pids, state.force_tie, inbox,
                state.chat_seq, state.roster_names, state.slot_persona,
                state)
        else
            ok_vote, vote_err = vote.run_vote_round(
                game_id, state.round, state.alive, state.roles,
                state.player_slot, state.npc_pids, state.force_tie, inbox)
        end
        if not ok_vote then
            logger:error("[orchestrator] run_vote_round failed",
                { err = tostring(vote_err) })
            break
        end

        -- LOOP-10: win check after the lynch. On tie, state.alive is unchanged so
        -- check_win returns nil again and the loop advances to the next Night.
        winner, living_mafia, living_villagers = end_game.check_win(state.alive, state.roles)

        -- If the game continues, DO NOT auto-advance to the next Night. Publish
        -- `day.vote_complete` so the SPA can enable its "Start next day" button,
        -- then block until the user clicks it. If there's a winner we fall
        -- through to the shutdown cascade below without waiting.
        --
        -- User-gated for alive AND dead players: a dead human still sees the
        -- reveal and must click "Start next day" like anyone else. The gate
        -- below does not look at `alive[player_slot]`.
        if not winner then
            -- Drain any in-flight messages before opening the gate. Without
            -- this a stale `player.advance_phase` (e.g. a rapid double-click
            -- on End-Discussion, silently dropped while run_vote_round_llm
            -- was collecting votes) can land in the inbox during the
            -- persist/tally/publish window and get consumed immediately by
            -- the await below — auto-advancing to the next night with no
            -- user action. Most visible when the human is dead because the
            -- vote round finishes fast (no wait for the human's vote).
            local pre_gate_drain = time.after("50ms")
            while true do
                local r = channel.select({ inbox:case_receive(), pre_gate_drain:case_receive() })
                if not r.ok or r.channel == pre_gate_drain then break end
                -- discard every pre-gate message
            end

            pe.publish_event("system", "day.vote_complete", "/" .. game_id, {
                round = state.round,
            })
            append_dev_event(state, "system", "day.vote_complete", "/" .. game_id)
            emit_dev_snapshot(state)
            logger:info("[orchestrator] vote round complete, awaiting user advance",
                { round = state.round })
            while true do
                local r = channel.select({ inbox:case_receive() })
                if not r.ok then break end
                local msg = r.value
                if msg and msg:topic() == "player.advance_phase" then
                    -- Round match: discard any cross-round stale message
                    -- that slipped past the drain (e.g. a second click
                    -- queued during the previous round's gate).
                    local raw = (msg:payload() and msg:payload():data()) or {}
                    if tonumber(raw.round) == state.round then break end
                end
                -- drop everything else
            end
        end
    end

    if winner then
        state.phase = "ended"
        emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
            state.roster_names, player_slot, "ended", state.round, false, winner)
        append_dev_event(state, "system", "game_state_changed", "/" .. game_id)
        emit_dev_snapshot(state)
        end_game.shutdown_cascade(game_id, state.round, winner,
            living_mafia, living_villagers, state.npc_pids)
        return { status = "ended", winner = winner, final_round = state.round }
    end

    -- Error path (night/day/vote helper returned nil) — cascade cancel and exit.
    logger:error("[orchestrator] FSM terminated without winner (helper error)",
        { game_id = game_id, round = state.round })
    for _, pid in pairs(state.npc_pids) do
        process.cancel(pid, "500ms")
    end
    return { status = "error", game_id = game_id }
end

return { run = run }
