-- src/game/vote.lua
-- Two-stage informed voting non-negotiable (CLAUDE.md): private suspicion update →
-- agent runner:step with tool_call="any" returning {vote_target, reasoning, suspicion_updates}
-- (Phase 7: schema-as-tool dispatch via app.npc.agents:vote_tool).
-- LOOP-08 (simultaneous voting): vote.prompt sent to ALL alive NPCs before any reply.
-- LOOP-09 (tie handling): tied max → NO elimination; publish vote.tied → next Night.
-- LOOP-10 (win check): check_win runs after every elimination (post-vote + post-night).
-- Dead-player UI guard: alive[player_slot] checked; dead human's stubbed vote excluded
-- when alive[player_slot] is false (canonical liveness field).
-- D-15 invariant: chat.line events (last_words) ONLY via chat.commit_chat_line.
-- Atomic end-of-game frame: emit_game_state_changed preserves winner on phase="ended".

local logger       = require("logger"):named("vote")
local time         = require("time")
local sql          = require("sql")
local channel      = require("channel")
local json         = require("json")
local pe           = require("pe")
local chat         = require("chat")
local game_state   = require("game_state")
local dev_telemetry = require("dev_telemetry")

-- Convenience aliases matching orchestrator.lua convention.
local dev_mode                    = dev_telemetry.dev_mode
local append_dev_event            = dev_telemetry.append_dev_event
local emit_game_state_changed     = game_state.emit_game_state_changed
local emit_game_state_changed_elim = game_state.emit_game_state_changed_elim

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
        if type(npc_pid) == "string" then
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
        if type(pid) == "string" then
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
        if alive[slot] and slot ~= player_slot and type(npid) == "string" then
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
    if top_slot ~= player_slot and type(victim_pid) == "string" then
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
                    local _, werr = chat.commit_npc_chat_with_delay(game_id, round, top_slot_i,
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

return {
    alive_slots_array = alive_slots_array,
    gather_votes = gather_votes,
    persist_votes = persist_votes,
    tally_votes = tally_votes,
    persist_lynch = persist_lynch,
    run_vote_round = run_vote_round,
    run_vote_round_llm = run_vote_round_llm,
}
