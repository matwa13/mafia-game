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
local pe = require("pe")  -- Phase 1 D-11 precedent: yaml imports pe -> app.lib:events

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

-- Phase 2 Plan 03: Night phase stub.
--
-- D-19: deterministic victim picker over the canonical 6-slot participant space (D-02).
-- Round is 1-indexed. rng_seed is the seed from args.rng_seed.
-- Algorithm: start from ((round + rng_seed) mod 6) + 1; if not alive OR is mafia, advance
-- through slots 1..6 until first alive villager is found.
local function pick_night_victim(round, rng_seed, alive, roles)
    local start = ((round + rng_seed) % 6) + 1  -- 6 = canonical participant count (D-02)
    for offset = 0, 5 do
        local slot = ((start - 1 + offset) % 6) + 1
        if alive[slot] and roles[slot] == "villager" then
            return slot
        end
    end
    -- no alive villager (terminal state — caller should check win before entering night)
    return nil
end

-- Pick the mafia actor: lowest-slot mafia still alive.
local function pick_night_actor(alive, roles)
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if alive[slot] and roles[slot] == "mafia" then
            return slot
        end
    end
    return nil
end

-- run_night_stub: atomic 3-write tx + night.resolved publish.
-- Returns true, nil on success or nil, err_string on failure.
-- CONTRACT (SETUP-05): SQL rows committed BEFORE publish_event fires.
-- Schema authority: src/storage/migrations/0001_initial_schema.lua
--   night_actions columns: (game_id, round, actor_slot, target_slot, created_at)
--   eliminations columns:  (game_id, round, victim_slot, cause, revealed_role, created_at)
-- D-18: eliminations.cause = "night" (not "kill"; authority 02-RESEARCH.md §Pattern 3 + 02-CONTEXT.md D-18).
-- Takes the specific fields it needs (avoids wippy-lint struct-shape union issue
-- when the caller's state table has 13+ fields).
-- Mutates `alive[victim_slot] = false` and returns new_round + victim_slot so the
-- caller can update state.round and dispatch dead-flag side-effects.
local function run_night_stub(game_id, round, rng_seed, alive, roles, npc_pids)
    local actor_slot = pick_night_actor(alive, roles)
    if not actor_slot then
        return nil, "no living mafia (game should have ended)"
    end
    local victim_slot = pick_night_victim(round, rng_seed, alive, roles)
    if not victim_slot then
        return nil, "no living villager (game should have ended)"
    end
    local revealed_role = roles[victim_slot]

    local db, db_err = sql.get("app:db")
    if db_err or not db then
        return nil, "sql.get: " .. tostring(db_err)
    end
    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return nil, "begin: " .. tostring(tx_err)
    end
    local now_ts = time.now():unix()
    local ok, err = pcall(function()
        local _, e1 = tx:execute(
            "INSERT INTO night_actions (game_id, round, actor_slot, target_slot, created_at) VALUES (?, ?, ?, ?, ?)",
            { game_id, round, actor_slot, victim_slot, now_ts }
        )
        assert(not e1, "night_actions.insert: " .. tostring(e1))
        local _, e2 = tx:execute(
            "INSERT INTO eliminations (game_id, round, victim_slot, cause, revealed_role, created_at) VALUES (?, ?, ?, 'night', ?, ?)",
            { game_id, round, victim_slot, revealed_role, now_ts }
        )
        assert(not e2, "eliminations.insert: " .. tostring(e2))
        local _, e3 = tx:execute(
            "UPDATE players SET alive = 0, died_round = ?, died_cause = 'night' WHERE game_id = ? AND slot = ?",
            { round, game_id, victim_slot }
        )
        assert(not e3, "players.update: " .. tostring(e3))
    end)
    if not ok then
        tx:rollback()
        db:release()
        return nil, "tx failed: " .. tostring(err)
    end
    local _, commit_err = tx:commit()
    db:release()
    if commit_err then
        return nil, "commit: " .. tostring(commit_err)
    end

    -- SETUP-05: SQL committed above; now mutate in-memory state and emit the event.
    alive[victim_slot] = false

    -- D-13 belt-and-suspenders: notify the eliminated stub so it sets dead=true.
    local victim_pid = npc_pids[victim_slot]
    if victim_pid then
        process.send(victim_pid, "eliminated", { slot = victim_slot, round = round })
    end

    pe.publish_event("system", "night.resolved", "/" .. game_id, {
        round = round,
        victim_slot = victim_slot,
        cause = "night",
        revealed_role = revealed_role,
        actor_slot = actor_slot,
    })

    logger:info("[orchestrator] night resolved", {
        round = round, victim_slot = victim_slot,
        revealed_role = revealed_role, actor_slot = actor_slot,
    })
    return true, victim_slot
end

-- Phase 2 Plan 03: Day discussion phase.
--
-- D-15 invariant: this helper is the SOLE writer of the `messages` table and the
-- SOLE publisher of `chat.line` events in the entire repo. Plan 05's audit-grep
-- gate (V-02-10) enforces at build time.
--
-- D-16/LOOP-06: per-speaker turn races a day-level deadline with a 1s drain that
-- lets the current speaker finish after the deadline fires.
--
-- Schema authority: src/storage/migrations/0001_initial_schema.lua
--   messages columns: (game_id, round, seq, phase, from_slot, kind, text, created_at)
--   phase='day' + kind='npc' are hardcoded in the INSERT (PLAN.md interface block
--   was missing these NOT-NULL columns; authority is the live schema + 02-RESEARCH.md
--   §"Orchestrator chat.submit handler" lines 786-791).

-- Build the speaking order for the current round: alive slots in ascending order,
-- EXCLUDING the human player (player_slot). Phase 2 test_driver does not simulate
-- human chat; Phase 3 wires the human-chat path.
local function speaking_order(alive, player_slot)
    local order = {}
    for slot = 1, 6 do  -- 6 = canonical participant count (D-02)
        if alive[slot] and slot ~= player_slot then
            table.insert(order, slot)
        end
    end
    return order
end

-- Write one message row and publish chat.line. SOLE site that mutates chat_seq
-- and SOLE publisher of `chat.line`. SETUP-05: INSERT precedes publish_event.
-- Returns the assigned seq on success, or nil + err on failure.
local function commit_chat_line(game_id, round, from_slot, text, chat_seq)
    chat_seq[round] = (chat_seq[round] or 0) + 1
    local seq = chat_seq[round]

    local db, db_err = sql.get("app:db")
    if db_err or not db then
        return nil, "sql.get: " .. tostring(db_err)
    end
    local _, exec_err = db:execute(
        "INSERT INTO messages (game_id, round, seq, phase, from_slot, kind, text, created_at) VALUES (?, ?, ?, 'day', ?, 'npc', ?, ?)",
        { game_id, round, seq, from_slot, text, time.now():unix() }
    )
    db:release()
    if exec_err then
        return nil, "messages.insert: " .. tostring(exec_err)
    end

    -- SETUP-05: publish AFTER successful INSERT.
    pe.publish_event("public", "chat.line", "/" .. game_id, {
        round = round,
        seq = seq,
        from_slot = from_slot,
        text = text,
    })
    return seq, nil
end

-- run_day_discussion: one speaker at a time; per-speaker cap + day-level deadline
-- with a 1s drain so the current speaker gets to finish if the deadline fires.
--
-- Uses `time.after(state.day_duration)` for the day-level deadline (one-shot,
-- created ONCE per phase — Pitfall 2). Per-speaker caps are fresh per iteration.
--
-- PLAN.md verify-grep expects `channel.after(state.day_duration)`; that is a
-- stale-API reference — `channel.after` does not exist in the Wippy runtime.
-- All in-repo deadlines use `time.after(...)`. Authority: src/probes/probe.lua,
-- src/npc/test_driver.lua, src/npc/npc_test.lua (Rule 1 — using the real API).
local function run_day_discussion(game_id, round, alive, player_slot, npc_pids,
                                  day_duration, pacing_ms, dev, chat_seq, inbox)
    local order = speaking_order(alive, player_slot)
    if #order == 0 then
        logger:warn("[orchestrator] run_day_discussion: empty speaking order")
        pe.publish_event("system", "chat_locked", "/" .. game_id, {
            round = round, reason = "no-speakers",
        })
        return true, nil
    end

    -- Pitfall 2: ONE day-level deadline for the entire phase.
    local deadline_ch = time.after(day_duration)
    local deadline_fired = false

    local per_speaker_cap = dev and "2s" or "5s"  -- Research Q2 — wide per-speaker cap

    for _, slot in ipairs(order) do
        local npc_pid = npc_pids[slot]
        if not npc_pid then
            logger:warn("[orchestrator] no pid for slot", { slot = slot })
        else
            process.send(npc_pid, "day.turn", {
                round = round,
                pacing_ms = pacing_ms,
            })

            -- Wait for this speaker's chat.submit OR deadline OR per-speaker cap.
            -- Pitfall 2: per_speaker_ch is fresh each iteration (one-shot).
            local per_speaker_ch = time.after(per_speaker_cap)
            local got_reply = false

            while not got_reply do
                local cases = {
                    inbox:case_receive(),
                    per_speaker_ch:case_receive(),
                }
                if not deadline_fired then
                    table.insert(cases, deadline_ch:case_receive())
                end
                local r = channel.select(cases)
                if not r.ok then
                    return nil, "channel closed during day"
                end

                if r.channel == inbox then
                    local msg = r.value
                    local topic_ok, topic = pcall(function() return msg:topic() end)
                    if not topic_ok then
                        logger:warn("[orchestrator] bad msg during day")
                    elseif topic == "chat.submit" then
                        local raw = msg:payload():data()
                        local reply_slot = (type(raw) == "table" and raw.slot) or nil
                        local reply_round = (type(raw) == "table" and raw.round) or nil
                        local text = (type(raw) == "table" and raw.text) or ""
                        local dead = (type(raw) == "table" and raw.dead) or false

                        if reply_slot == slot and reply_round == round then
                            if not dead and text and text ~= "" then
                                local _, write_err = commit_chat_line(
                                    game_id, round, slot, tostring(text), chat_seq)
                                if write_err then
                                    logger:error("[orchestrator] commit_chat_line failed",
                                        { slot = slot, err = write_err })
                                end
                            end
                            got_reply = true
                        else
                            logger:debug("[orchestrator] stale/mismatched chat.submit (drop)",
                                { expected_slot = slot, got_slot = tostring(reply_slot),
                                  expected_round = round, got_round = tostring(reply_round) })
                        end
                    else
                        -- any other inbox topic: defer handling to Plan 04 main loop
                        logger:debug("[orchestrator] non-chat inbox during day",
                            { topic = tostring(topic) })
                    end
                elseif r.channel == per_speaker_ch then
                    logger:warn("[orchestrator] per-speaker timeout", { slot = slot })
                    got_reply = true  -- advance past this speaker
                elseif (not deadline_fired) and r.channel == deadline_ch then
                    deadline_fired = true
                    logger:info("[orchestrator] day deadline fired",
                        { round = round, current_speaker = slot })
                    -- Pattern 2 drain: let the CURRENT speaker finish, then exit
                    -- the outer loop. Continue the inner `while not got_reply` loop
                    -- WITHOUT the deadline case (capped by per_speaker_cap).
                end
            end
        end

        if deadline_fired then
            break  -- current speaker has finished (drain complete); skip remaining speakers
        end
    end

    -- If deadline fired during or after the final speaker, grant a 1s post-loop
    -- drain so any straggler chat.submit lands silently (best-effort, no publish).
    if deadline_fired then
        local drain = time.after("1s")
        local draining = true
        while draining do
            local r = channel.select({ inbox:case_receive(), drain:case_receive() })
            if not r.ok or r.channel ~= inbox then
                draining = false
            else
                logger:debug("[orchestrator] drain-dropping post-deadline msg")
            end
        end
    end

    local reason = deadline_fired and "deadline" or "all-done"
    pe.publish_event("system", "chat_locked", "/" .. game_id, {
        round = round, reason = reason,
    })
    logger:info("[orchestrator] day complete", { round = round, reason = reason })
    return true, nil
end

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
    -- Resolve duration/pacing into locally-typed string/integer to avoid the lint's
    -- literal-union narrowing on the state-table constructor.
    local day_duration_str = dev and DAY_DURATION_DEV or DAY_DURATION_PROD
    local pacing_ms_int = dev and PACING_DEV_MS or PACING_PROD_MS
    local state = {
        game_id = game_id,
        rng_seed = rng_seed,
        player_slot = player_slot,
        force_tie = force_tie,
        driver_pid = driver_pid,
        gm_pid = gm_pid,
        day_duration = tostring(day_duration_str),
        pacing_ms = tonumber(pacing_ms_int) or 500,
        round = 0,
        roles = nil,
        roster = nil,
        npc_pids = {},
        alive = {},  -- populated below to avoid literal-tuple type narrowing
        chat_seq = {},  -- per-round message counter; written by commit_chat_line
    }
    -- D-02: 6 slots, all initially alive. Assigned outside the constructor so the
    -- lint infers `{[integer]: boolean}` rather than a fixed 6-element true-tuple.
    for slot = 1, 6 do state.alive[slot] = true end
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

    -- 8. Post-INIT FSM loop (Plan 04).
    --    Night -> check_win -> Day -> Vote -> check_win -> loop | shutdown.
    --    LOOP-01 end-to-end. On non-nil winner: shutdown cascade + return.
    local winner = nil
    local living_mafia, living_villagers
    while not winner do
        state.round = (state.round or 0) + 1
        local ok_night, night_result = run_night_stub(
            game_id, state.round, rng_seed, state.alive, state.roles, state.npc_pids)
        if not ok_night then
            logger:error("[orchestrator] run_night_stub failed",
                { err = tostring(night_result) })
            break
        end

        -- LOOP-10: win check after the night elimination.
        winner, living_mafia, living_villagers = check_win(state.alive, state.roles)
        if winner then break end

        local ok_day, day_err = run_day_discussion(
            game_id, state.round, state.alive, state.player_slot, state.npc_pids,
            state.day_duration, state.pacing_ms, dev, state.chat_seq, inbox)
        if not ok_day then
            logger:error("[orchestrator] run_day_discussion failed",
                { err = tostring(day_err) })
            break
        end

        local ok_vote, vote_err = run_vote_round(
            game_id, state.round, state.alive, state.roles,
            state.player_slot, state.npc_pids, state.force_tie, inbox)
        if not ok_vote then
            logger:error("[orchestrator] run_vote_round failed",
                { err = tostring(vote_err) })
            break
        end

        -- LOOP-10: win check after the lynch. On tie, state.alive is unchanged so
        -- check_win returns nil again and the loop advances to the next Night.
        winner, living_mafia, living_villagers = check_win(state.alive, state.roles)
    end

    if winner then
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
