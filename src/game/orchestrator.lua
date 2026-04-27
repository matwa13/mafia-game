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


-- Phase 2 Plan 04: Vote phase + tally + win check + shutdown cascade.
--
-- LOOP-08 (simultaneous voting): vote.prompt is sent to every alive NPC BEFORE
-- any reply is processed; tally runs only AFTER all replies collected (or deadline).
-- LOOP-09 (tie handling): if max vote-count is tied at >=2 slots, NO elimination;
-- publish `vote.tied` on `mafia.system` and proceed to next night.
-- LOOP-10 (win check): `check_win` runs after every elimination (post-night + post-vote).
-- LOOP-01 (FSM end-to-end): the main loop drives Night -> Day -> Vote -> check_win
-- until a winner emerges, then the shutdown cascade fires.
--
-- Schema authority: src/storage/migrations/0001_initial_schema.lua
--   votes columns:        (game_id, round, from_slot, vote_for_slot, reasoning, created_at)
--   eliminations columns: (game_id, round, victim_slot, cause, revealed_role, created_at)
--   games columns:        (id, started_at, ended_at, winner, player_slot, player_role, rng_seed)
--
-- SETUP-05 ordering: every SQL commit precedes its paired publish_event. The lynch
-- path wraps INSERT eliminations + UPDATE players in ONE db:begin tx (Pattern 3).
-- Shutdown cascade writes UPDATE games BEFORE publishing game.ended.
--
-- Pitfall 3: process.cancel is NOT automatic on clean parent return. The shutdown
-- cascade explicitly cancels each npc_pid with a 500ms grace.

-- Build the alive-slots array (sorted ascending) for a vote.prompt payload.
-- Stub normalizes array -> set via `for _, s in ipairs ... do alive[s] = true end`.
local function alive_slots_array(alive)
    local arr = {}
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if alive[slot] then table.insert(arr, slot) end
    end
    return arr
end

-- Collect one vote.cast per alive NPC + a deterministic stubbed player vote.
-- LOOP-08: vote.prompt is sent to ALL alive NPCs before any reply is processed.
-- Returns votes_map { from_slot -> vote_for_slot or nil } (may be partial on deadline).
local function gather_votes(game_id, round, alive, player_slot, npc_pids, force_tie, inbox)
    local alive_arr = alive_slots_array(alive)

    -- Build set of alive NPC slots we are awaiting (exclude player).
    local awaiting = {}
    local expected_count = 0
    for _, slot in ipairs(alive_arr) do
        if slot ~= player_slot then
            awaiting[slot] = true
            expected_count = expected_count + 1
        end
    end

    -- Simultaneous: send vote.prompt to all alive NPCs BEFORE collecting any reply.
    for slot in pairs(awaiting) do
        local npc_pid = npc_pids[slot]
        if npc_pid then
            process.send(npc_pid, "vote.prompt", {
                round = round,
                alive_slots = alive_arr,
                force_tie = force_tie == true,
            })
        end
    end

    local votes = {}

    -- Stub the human player's vote: in Phase 2 the player is a "cooperative tester",
    -- always votes for slot 2 unless player_slot==2, in which case slot 3. If the
    -- preferred target is dead, fall back to first alive non-self slot. This keeps
    -- V-02-05 deterministic without requiring a WS client or Phase 3 driver wiring.
    if alive[player_slot] then
        local player_target = player_slot == 2 and 3 or 2
        if not alive[player_target] then
            for _, s in ipairs(alive_arr) do
                if s ~= player_slot then player_target = s; break end
            end
        end
        votes[player_slot] = player_target
    end

    -- Collect NPC replies with a 5s deadline. Deadline is one-shot (Pitfall 2).
    local deadline = time.after("5s")
    local collected = 0
    while collected < expected_count do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel ~= inbox then
            logger:warn("[orchestrator] gather_votes deadline", {
                collected = collected, expected = expected_count,
            })
            break
        end
        local msg = r.value
        local topic_ok, topic = pcall(function() return msg:topic() end)
        if topic_ok and topic == "vote.cast" then
            local raw = msg:payload():data()
            if type(raw) == "table" then
                local from_slot = raw.from_slot
                local vote_for = raw.vote_for_slot
                local reply_round = raw.round
                if from_slot and reply_round == round and awaiting[from_slot] then
                    votes[from_slot] = vote_for  -- may be nil for dead stubs (D-13)
                    awaiting[from_slot] = nil
                    collected = collected + 1
                end
            end
        end
    end
    return votes
end

-- Persist one `votes` row per voter. Skips abstentions (vote_for_slot == nil).
-- Plain per-row db:execute (no tx — votes PK {game_id, round, from_slot} dedupes
-- and no cross-table atomicity needed here).
local function persist_votes(game_id, round, votes_map)
    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil, "sql.get: " .. tostring(db_err) end
    local now_ts = time.now():unix()
    local any_err = nil
    for from_slot, vote_for_slot in pairs(votes_map) do
        if vote_for_slot ~= nil then  -- skip abstentions / dead stubs (D-13)
            local _, exec_err = db:execute(
                "INSERT INTO votes (game_id, round, from_slot, vote_for_slot, reasoning, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                { game_id, round, from_slot, vote_for_slot, "stub", now_ts }
            )
            if exec_err then any_err = tostring(exec_err); break end
        end
    end
    db:release()
    if any_err then return nil, "votes.insert: " .. any_err end
    return true, nil
end

-- Tally: return (top_slot, tied_slots_array, tally_map).
-- tied_slots_array has >=2 entries IFF there is a tie at the max.
-- top_slot is nil on empty map OR on tie.
local function tally_votes(votes_map)
    local tally = {}
    for _, target in pairs(votes_map) do
        if target ~= nil then tally[target] = (tally[target] or 0) + 1 end
    end
    local max_count = 0
    for _, c in pairs(tally) do if c > max_count then max_count = c end end
    local tied = {}
    for slot, c in pairs(tally) do
        if c == max_count then table.insert(tied, slot) end
    end
    table.sort(tied)
    if max_count == 0 then return nil, {}, tally end  -- no votes at all
    if #tied == 1 then return tied[1], {}, tally end
    return nil, tied, tally
end

-- Persist a lynch: INSERT eliminations + UPDATE players, atomic (Pattern 3).
-- Returns revealed_role on success, or nil+err on failure.
local function persist_lynch(game_id, round, victim_slot, roles)
    local revealed_role = roles[victim_slot]
    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil, "sql.get: " .. tostring(db_err) end
    local tx, tx_err = db:begin()
    if tx_err then db:release(); return nil, "begin: " .. tostring(tx_err) end
    local now_ts = time.now():unix()
    local ok, err = pcall(function()
        local _, e1 = tx:execute(
            "INSERT INTO eliminations (game_id, round, victim_slot, cause, revealed_role, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            { game_id, round, victim_slot, "lynch", revealed_role, now_ts }
        )
        assert(not e1, "eliminations.insert: " .. tostring(e1))
        local _, e2 = tx:execute(
            "UPDATE players SET alive = 0, died_round = ?, died_cause = ? WHERE game_id = ? AND slot = ?",
            { round, "lynch", game_id, victim_slot }
        )
        assert(not e2, "players.update: " .. tostring(e2))
    end)
    if not ok then tx:rollback(); db:release(); return nil, "tx: " .. tostring(err) end
    local _, commit_err = tx:commit()
    db:release()
    if commit_err then return nil, "commit: " .. tostring(commit_err) end
    return revealed_role, nil
end

-- run_vote_round: full phase — gather, persist, tally, lynch-or-tie, emit events.
-- SETUP-05: persist_lynch's tx commits BEFORE player.eliminated publish.
-- Takes explicit fields (not the state table) to avoid wippy-lint struct-shape
-- union issues — same pattern as run_night_stub / run_day_discussion.
local function run_vote_round(game_id, round, alive, roles, player_slot, npc_pids, force_tie, inbox)
    local votes = gather_votes(game_id, round, alive, player_slot, npc_pids, force_tie, inbox)
    local persist_ok, persist_err = persist_votes(game_id, round, votes)
    if not persist_ok then return nil, persist_err end

    local top_slot, tied, tally = tally_votes(votes)

    if top_slot then
        -- Lynch path (LOOP-08).
        local revealed_role, lynch_err = persist_lynch(game_id, round, top_slot, roles)
        if not revealed_role then return nil, lynch_err end
        alive[top_slot] = false

        -- D-13 belt-and-suspenders: notify the lynched stub so it sets dead=true.
        local pid = npc_pids[top_slot]
        if pid then
            process.send(pid, "eliminated", { slot = top_slot, round = round })
        end

        -- SETUP-05: publish AFTER tx:commit (persist_lynch returned revealed_role).
        pe.publish_event("public", "player.eliminated", "/" .. game_id, {
            round = round,
            victim_slot = top_slot,
            cause = "lynch",
            revealed_role = revealed_role,
            tally = tally,
        })
        logger:info("[orchestrator] lynch", {
            round = round, victim_slot = top_slot, revealed_role = revealed_role,
        })
    else
        -- Tie path (LOOP-09): no eliminations row, proceed to next Night.
        pe.publish_event("system", "vote.tied", "/" .. game_id, {
            round = round,
            tied_slots = tied,
            tally = tally,
        })
        logger:info("[orchestrator] vote tied", {
            round = round, tied_count = #tied,
        })
    end
    return true, nil
end

-- Phase 3: run_vote_round_llm.
-- Same outer contract as run_vote_round but:
--   - gathers full reasoning string from each vote.cast payload
--   - publishes public/votes_revealed with per_voter array before persist_lynch
--   - preserves Phase 2 tally + tie-handling logic
--   - uses alive as the canonical and SOLE liveness field (Phase 2 invariant)
-- Takes explicit state fields (chat_seq, roster_names, slot_persona) instead of
-- the state table — avoids wippy-lint struct-shape union issues.
local function run_vote_round_llm(game_id, round, alive, roles, player_slot, npc_pids,
                                   force_tie, inbox, chat_seq, roster_names, slot_persona,
                                   dev_state)
    -- local helper: count table entries
    local function count_map(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    -- Fan-out vote.prompt to all living NPCs (player excluded).
    for slot = 1, 6 do
        local npid = npc_pids[slot]
        if alive[slot] and slot ~= player_slot and npid then
            process.send(npid, "vote.prompt", { round = round })
        end
    end

    -- Count living participants (NPCs + player) to know when collection is complete.
    local needed = 0
    for slot = 1, 6 do if alive[slot] then needed = needed + 1 end end

    local votes_by_slot = {}  -- [slot] = { vote_for_slot, reasoning }
    -- vote_cap must exceed npc.lua VOTE_CAP_S (15s structured_output deadline)
    -- or NPC vote.casts arrive AFTER the orchestrator has already tallied.
    -- Also must give the human player realistic time to read reasoning + pick.
    -- Early-exit via `count_map(votes_by_slot) >= needed` still fires as soon
    -- as the last vote (usually the player's) arrives.
    local vote_cap = time.after(dev_mode() and "120s" or "180s")
    while true do
        local r = channel.select({ inbox:case_receive(), vote_cap:case_receive() })
        if not r.ok or r.channel == vote_cap then
            logger:warn("[orchestrator] vote collection timeout",
                { round = round, collected = count_map(votes_by_slot), needed = needed })
            break
        end
        local msg = r.value
        local tp = msg:topic()
        if tp == "vote.cast" then
            local raw = (msg:payload():data()) or {}
            if (raw.round == round) and raw.from_slot and not votes_by_slot[raw.from_slot] then
                votes_by_slot[raw.from_slot] = {
                    vote_for_slot = raw.vote_for_slot,
                    reasoning = tostring(raw.reasoning or ""),
                }
                -- Incremental reveal: publish each vote as it lands so the SPA
                -- can flip the placeholder bubble to a revealed card without
                -- waiting for the full `votes_revealed` event at the end.
                pe.publish_event("public", "vote.cast.received", "/" .. game_id, {
                    round = round,
                    from_slot = raw.from_slot,
                    from_name = (roster_names and roster_names[raw.from_slot])
                        or ("slot-" .. tostring(raw.from_slot)),
                    vote_for_slot = raw.vote_for_slot,
                    reasoning = tostring(raw.reasoning or ""),
                })
                if dev_state then append_dev_event(dev_state, "public", "vote.cast.received", "/" .. game_id) end
                if count_map(votes_by_slot) >= needed then break end
            end
        end
    end

    -- Persist votes with reasoning strings.
    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil, "sql.get: " .. tostring(db_err) end
    local now_ts = time.now():unix()
    for slot, v in pairs(votes_by_slot) do
        local _, werr = db:execute(
            "INSERT OR REPLACE INTO votes (game_id, round, from_slot, vote_for_slot, reasoning, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            { game_id, round, slot, v.vote_for_slot, v.reasoning, now_ts }
        )
        if werr then
            logger:error("[orchestrator] persist vote failed", { slot = slot, err = tostring(werr) })
        end
    end
    db:release()

    -- Tally. Keys are STRINGIFIED slot numbers so the JSON transcoder on the
    -- WebSocket boundary doesn't see a sparse integer-keyed table (e.g.
    -- {2: 3, 6: 2}) which it refuses to encode ("cannot encode sparse array").
    local tally = {}
    for _, v in pairs(votes_by_slot) do
        if v.vote_for_slot and alive[v.vote_for_slot] then
            local k = tostring(v.vote_for_slot)
            tally[k] = (tally[k] or 0) + 1
        end
    end
    local top_slot, top_count, tied = nil, 0, false
    for s, c in pairs(tally) do
        -- Keys are stringified (line ~1186); coerce back to integer so lint
        -- accepts `top_slot` as an index into integer-keyed maps (npc_pids, alive).
        if c > top_count then top_slot = math.floor(tonumber(s) or 0); top_count = c; tied = false
        elseif c == top_count then tied = true end
    end
    if force_tie then tied = true; top_slot = nil end

    -- Build per_voter array (sorted by slot for deterministic UI output).
    local per_voter = {}
    for slot = 1, 6 do
        if votes_by_slot[slot] then
            table.insert(per_voter, {
                from_slot = slot,
                from_name = (roster_names and roster_names[slot]) or ("slot-" .. slot),
                vote_for_slot = votes_by_slot[slot].vote_for_slot,
                reasoning = votes_by_slot[slot].reasoning,
            })
        end
    end

    -- PUBLISH votes_revealed BEFORE lynch so UI can animate reveal.
    pe.publish_event("public", "votes_revealed", "/" .. game_id, {
        round = round, tally = tally, per_voter = per_voter,
        top_slot = (not tied) and top_slot or nil, tied = tied,
    })
    if dev_state then append_dev_event(dev_state, "public", "votes_revealed", "/" .. game_id) end

    if tied or not top_slot then
        pe.publish_event("system", "vote.tied", "/" .. game_id, { round = round, tally = tally })
        if dev_state then append_dev_event(dev_state, "system", "vote.tied", "/" .. game_id) end
        emit_game_state_changed(game_id, alive, roles, slot_persona,
            roster_names, player_slot, "reveal", round, true)
        if dev_state then append_dev_event(dev_state, "system", "game_state_changed", "/" .. game_id) end
        return true, nil
    end

    -- Lynch top slot via Phase 2 persist_lynch (unchanged).
    local revealed_role, lynch_err = persist_lynch(game_id, round, top_slot, roles)
    if lynch_err then
        logger:error("[orchestrator] persist_lynch failed", { err = tostring(lynch_err) })
        return nil, lynch_err
    end
    -- Mark slot eliminated via alive (Phase 2 canonical field at orchestrator.lua:785).
    -- No parallel eliminated-slot table exists; alive[slot] = false IS the canonical mutation.
    alive[top_slot] = false

    -- Last-words dispatch (NPC-09) — only for NPC slots, not the player.
    local victim_pid = npc_pids[top_slot]
    if top_slot ~= player_slot and victim_pid then
        process.send(victim_pid, "eliminated", {
            slot = top_slot, round = round, request_last_words = true,
        })
        local lw_deadline = time.after("12s")
        while true do
            local lwr = channel.select({ inbox:case_receive(), lw_deadline:case_receive() })
            if not lwr.ok or lwr.channel == lw_deadline then break end
            local m = lwr.value
            if m:topic() == "chat.submit" then
                local raw = (m:payload():data()) or {}
                if raw.from_slot == top_slot and raw.kind == "last_words" then
                    local top_slot_i = math.floor(tonumber(top_slot) or 0)
                    local _, werr = chat.commit_chat_line(game_id, round, top_slot_i,
                        tostring(raw.text or ""), chat_seq, "last_words")
                    if werr then
                        logger:warn("[orchestrator] last_words commit failed",
                            { err = tostring(werr) })
                    end
                    break
                end
            end
        end
    end

    -- Publish elimination event.
    pe.publish_event("public", "player.eliminated", "/" .. game_id, {
        round = round, victim_slot = top_slot, cause = "lynch", revealed_role = revealed_role,
    })
    if dev_state then append_dev_event(dev_state, "public", "player.eliminated", "/" .. game_id) end
    local victim_name = (roster_names and roster_names[top_slot]) or ("slot-" .. top_slot)
    emit_game_state_changed_elim(game_id, alive, roles, slot_persona,
        roster_names, player_slot, "reveal", round,
        top_slot, victim_name, revealed_role, "lynch")
    if dev_state then append_dev_event(dev_state, "system", "game_state_changed", "/" .. game_id) end

    -- Cancel the victim NPC process so it exits cleanly.
    if top_slot ~= player_slot and victim_pid then
        pcall(process.cancel, victim_pid, "500ms")
    end

    logger:info("[orchestrator] llm lynch", {
        round = round, victim_slot = top_slot, revealed_role = revealed_role,
    })
    return true, nil
end

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
        process.cancel(pid, "500ms")
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

    -- Intro gate: emit phase="intro" with full roster and block until the
    -- player explicitly starts the game. No night kill, no LLM calls, no
    -- chat until the gate exits via player.start_game.
    state.phase = "intro"
    emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
        state.roster_names, player_slot, "intro", 0, false)
    append_dev_event(state, "system", "game_state_changed", "/" .. game_id)

    logger:info("[orchestrator] intro gate: waiting for player.start_game",
        { game_id = game_id })
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

    -- 8. Post-INIT FSM loop (Plan 04).
    --    Night -> check_win -> Day -> Vote -> check_win -> loop | shutdown.
    --    LOOP-01 end-to-end. On non-nil winner: shutdown cascade + return.
    local winner = nil
    local living_mafia, living_villagers
    while not winner do
        state.round = (state.round or 0) + 1

        -- D-SCH-02 / WR-06: record phase visit. PK is (game_id, round); only the
        -- first phase per round actually writes — that's still enough to close WR-06.
        record_round_phase(game_id, state.round, "night")

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
        winner, living_mafia, living_villagers = check_win(state.alive, state.roles)
        if winner then break end

        -- D-SCH-02: record day phase visit (no-op due to PK if night already wrote).
        record_round_phase(game_id, state.round, "day")

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
        record_round_phase(game_id, state.round, "vote")

        state.phase = "vote"
        emit_game_state_changed(game_id, state.alive, state.roles, state.slot_persona,
            state.roster_names, player_slot, "vote", state.round, false)
        append_dev_event(state, "system", "game_state_changed", "/" .. game_id)
        emit_dev_snapshot(state)

        local ok_vote, vote_err
        if npc_mode() == "real" then
            ok_vote, vote_err = run_vote_round_llm(
                game_id, state.round, state.alive, state.roles,
                state.player_slot, state.npc_pids, state.force_tie, inbox,
                state.chat_seq, state.roster_names, state.slot_persona,
                state)
        else
            ok_vote, vote_err = run_vote_round(
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
        winner, living_mafia, living_villagers = check_win(state.alive, state.roles)

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
        shutdown_cascade(game_id, state.round, winner,
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
