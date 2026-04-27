-- src/game/night.lua
-- LOOP-02 (Villager branch): both Mafia NPCs pick via structured_output; orchestrator
-- gathers with deadline, tie-breaks on confidence, writes atomic SQL tx.
-- LOOP-03 (Mafia branch): human player picks with partner NPC side-chat.
-- Phase 4 success criterion: role-dependent night path (villager auto vs mafia human).
-- D-15 invariant: chat.line events emitted ONLY via chat.commit_chat_line (chat.lua).
-- D-SC-04: mafia side-chat persisted with kind='mafia_chat' scope='mafia'.

local logger    = require("logger"):named("night")
local time      = require("time")
local sql       = require("sql")
local channel   = require("channel")
local json      = require("json")
local pe        = require("pe")
local det_rng   = require("det_rng")
local chat      = require("chat")

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

-- Phase 4 LOOP-02 (Villager branch): Both Mafia NPCs pick in parallel via
-- structured_output. Orchestrator gathers replies with deadline, tie-breaks on
-- confidence (higher wins) then on lower slot, writes atomic SQL tx
-- (night_actions with reasoning_json, eliminations, players.alive=0), and
-- publishes night.resolved (system scope).
--
-- D-15 invariant unchanged: this helper does NOT publish "chat.line" — only
-- night.resolved. The mafia-human branch is the chat-line site.
--
-- Returns: true, victim_slot on success; nil, err_str on failure.
local function run_night_villager_auto(game_id, round, alive, roles, npc_pids, roster_names)
    -- 1. Find living Mafia NPCs (potential pickers).
    local mafia_pickers = {}
    for slot = 1, 6 do
        if alive[slot] and roles[slot] == "mafia" and npc_pids[slot] then
            table.insert(mafia_pickers, slot)
        end
    end
    if #mafia_pickers == 0 then
        return nil, "no living mafia NPCs (game should have ended)"
    end

    -- 2. Build living non-Mafia target list (slots + names).
    local living_target_slots = {}
    local living_target_names = {}
    for slot = 1, 6 do
        if alive[slot] and roles[slot] ~= "mafia" then
            table.insert(living_target_slots, slot)
            table.insert(living_target_names,
                (roster_names and roster_names[slot]) or ("slot-" .. slot))
        end
    end
    if #living_target_slots == 0 then
        return nil, "no living villagers (game should have ended)"
    end

    -- 3. Dispatch night.pick to every living Mafia NPC. Replies arrive on inbox.
    for _, mslot in ipairs(mafia_pickers) do
        process.send(npc_pids[mslot], "night.pick", {
            round = round,
            living_target_slots = living_target_slots,
            living_target_names = living_target_names,
        })
    end

    -- 4. Gather replies with hard deadline (slightly longer than NPC's VOTE_CAP_S
    --    to absorb network jitter).
    local inbox = process.inbox()
    local deadline = time.after("18s")
    local picks = {}  -- {[mafia_slot] = { target_slot, reasoning, confidence }}
    local got = 0
    local need = #mafia_pickers

    while got < need do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok then break end
        if r.channel == deadline then break end
        local msg = r.value
        local tp = msg and msg:topic() or ""
        if tp == "night.pick.response" then
            local raw = (msg:payload() and msg:payload():data()) or {}
            local from_slot = tonumber(raw.from_slot)
            local resp_round = tonumber(raw.round)
            -- Round-match guard (T-04-18): drop stale cross-round responses.
            if from_slot and roles[from_slot] == "mafia" and not picks[from_slot]
                and (resp_round == nil or resp_round == round) then
                picks[from_slot] = {
                    target_slot = tonumber(raw.target_slot),
                    reasoning = tostring(raw.reasoning or ""),
                    confidence = tonumber(raw.confidence) or 0,
                }
                got = got + 1
            end
        end
        -- ignore everything else during gather (player commands, stale events)
    end

    -- 5. Tie-break: higher confidence wins; on tie, lower mafia slot wins.
    local winning_actor_slot, winning_target_slot = nil, nil
    local winning_conf = -1
    local winning_reason = ""
    local tie_break_note = ""
    -- Build candidates (only mafia slots that responded with a target).
    local candidates = {}
    for _, mslot in ipairs(mafia_pickers) do
        if picks[mslot] and picks[mslot].target_slot then
            table.insert(candidates, { slot = mslot, pick = picks[mslot] })
        end
    end

    if #candidates == 0 then
        -- All NPCs failed/timed-out: fall back to the lowest-mafia-slot picking
        -- the first living non-Mafia. Better than crashing the FSM.
        winning_actor_slot = mafia_pickers[1]
        winning_target_slot = living_target_slots[1]
        winning_reason = "all_mafia_npcs_failed_fallback"
        winning_conf = 0
        tie_break_note = "fallback: zero responses"
    else
        for _, c in ipairs(candidates) do
            local p = c.pick
            local higher_conf = p.confidence > winning_conf
            local equal_conf_lower_slot = (p.confidence == winning_conf)
                and (winning_actor_slot == nil or c.slot < winning_actor_slot)
            if higher_conf or equal_conf_lower_slot then
                winning_actor_slot = c.slot
                winning_target_slot = p.target_slot
                winning_conf = p.confidence
                winning_reason = p.reasoning
            end
        end
        -- Compose tie-break note for reasoning_json: list all candidates' picks.
        local notes = {}
        for _, c in ipairs(candidates) do
            table.insert(notes, string.format(
                "NPC-%d picked slot %s confidence %d: %s",
                c.slot, tostring(c.pick.target_slot), c.pick.confidence, c.pick.reasoning))
        end
        tie_break_note = table.concat(notes, " | ")
            .. " | winner: NPC-" .. tostring(winning_actor_slot)
    end

    -- 6. Build reasoning_json (D-VR-03: persisted; not shown in-play).
    local json_ok, json_mod = pcall(require, "json")
    local reasoning_json
    if json_ok and json_mod and json_mod.encode then
        reasoning_json = json_mod.encode({
            picks = picks,
            winner_actor_slot = winning_actor_slot,
            winner_target_slot = winning_target_slot,
            winner_confidence = winning_conf,
            winner_reasoning = winning_reason,
            tie_break = tie_break_note,
            source = "villager_auto",
        })
    else
        reasoning_json = string.format(
            "{\"source\":\"villager_auto\",\"winner_actor_slot\":%d,\"winner_target_slot\":%s,\"winner_confidence\":%d,\"tie_break\":%q}",
            winning_actor_slot, tostring(winning_target_slot), winning_conf, tie_break_note)
    end
    reasoning_json = reasoning_json or "{}"

    -- 7. Atomic SQL transaction: night_actions + eliminations + players.UPDATE.
    --    Same shape as run_night_stub, plus reasoning_json column.
    local revealed_role = roles[winning_target_slot]
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
            "INSERT INTO night_actions (game_id, round, actor_slot, target_slot, created_at, reasoning_json) VALUES (?, ?, ?, ?, ?, ?)",
            { game_id, round, winning_actor_slot, winning_target_slot, now_ts, reasoning_json }
        )
        assert(not e1, "night_actions.insert: " .. tostring(e1))
        local _, e2 = tx:execute(
            "INSERT INTO eliminations (game_id, round, victim_slot, cause, revealed_role, created_at) VALUES (?, ?, ?, 'night', ?, ?)",
            { game_id, round, winning_target_slot, revealed_role, now_ts }
        )
        assert(not e2, "eliminations.insert: " .. tostring(e2))
        local _, e3 = tx:execute(
            "UPDATE players SET alive = 0, died_round = ?, died_cause = 'night' WHERE game_id = ? AND slot = ?",
            { round, game_id, winning_target_slot }
        )
        assert(not e3, "players.update: " .. tostring(e3))
    end)
    if not ok then
        tx:rollback(); db:release()
        return nil, "tx failed: " .. tostring(err)
    end
    local _, commit_err = tx:commit()
    db:release()
    if commit_err then
        return nil, "commit: " .. tostring(commit_err)
    end

    alive[winning_target_slot] = false
    local victim_pid = npc_pids[winning_target_slot]
    if victim_pid then
        process.send(victim_pid, "eliminated",
            { slot = winning_target_slot, round = round })
    end

    -- SETUP-05: publish AFTER successful commit.
    pe.publish_event("system", "night.resolved", "/" .. game_id, {
        round = round,
        victim_slot = winning_target_slot,
        cause = "night",
        revealed_role = revealed_role,
        actor_slot = winning_actor_slot,
    })

    logger:info("[orchestrator] night resolved (villager_auto)", {
        round = round,
        victim_slot = winning_target_slot,
        actor_slot = winning_actor_slot,
        confidence = winning_conf,
    })
    return true, winning_target_slot
end

-- Phase 4 LOOP-03 (Mafia branch): partner NPC opens with a side-chat suggestion;
-- human and partner alternate strictly; loop ends when human submits
-- player.night_pick. If partner is dead (D-SC-06), no side-chat — just wait for
-- the human's pick. All side-chat lines persist via commit_chat_line with
-- kind='mafia_chat' and scope='mafia' (D-SC-04 + D-15 SOLE writer).
--
-- chat_seq is the orchestrator's per-round seq counter; we reserve seq up-front
-- before each NPC dispatch to preserve the seq-authoritative invariant
-- (CLAUDE.md flow invariant — Phase 3 polish). The reply handler reuses the
-- pre-reserved seq via pending_reply_seq (B2 fix per D-FLAG-01).
--
-- Returns: true, victim_slot on success; nil, err_str on failure.
local function run_night_mafia_human(game_id, round, alive, roles, player_slot,
                                     npc_pids, chat_seq, inbox, roster_names)
    -- 1. Locate partner Mafia NPC (the OTHER mafia, not the human).
    local partner_slot = nil
    for slot = 1, 6 do
        if slot ~= player_slot and roles[slot] == "mafia" then
            partner_slot = slot
            break
        end
    end
    local partner_alive = partner_slot ~= nil and alive[partner_slot]

    -- 2. Build living non-Mafia target list.
    local living_target_slots = {}
    local living_target_names = {}
    for slot = 1, 6 do
        if alive[slot] and roles[slot] ~= "mafia" then
            table.insert(living_target_slots, slot)
            table.insert(living_target_names,
                (roster_names and roster_names[slot]) or ("slot-" .. slot))
        end
    end
    if #living_target_slots == 0 then
        return nil, "no living villagers"
    end

    -- 3. side_chat_history accumulates partner+human messages for partner's prompt context.
    local side_chat_history = {}

    -- 4. Open partner side-chat ONLY if partner alive (D-SC-06: partner dead → skip).
    -- Seq-authoritative invariant (CLAUDE.md Phase 3 polish): reserve seq BEFORE
    -- dispatch; the reply commit reuses the reserved value via pending_reply_seq.
    -- DO NOT increment chat_seq again on reply — that wastes the reservation
    -- and causes the partner's message to land at reserved+1 (gap at reserved).
    local partner_thinking = false
    local pending_reply_seq = nil  -- B2 fix per D-FLAG-01: pre-reserved reply seq.
    if partner_alive then
        chat_seq[round] = (chat_seq[round] or 0) + 1
        local reserved = chat_seq[round]
        pending_reply_seq = reserved
        partner_thinking = true
        process.send(npc_pids[partner_slot], "night.side_chat", {
            round = round,
            living_target_slots = living_target_slots,
            living_target_names = living_target_names,
            side_chat_history = side_chat_history,
            preassigned_seq = reserved,  -- echo back in reply for ordering
        })
    end

    -- 5. Loop until player.night_pick arrives. No upper message cap (D-SC-02).
    local victim_slot = nil
    while true do
        local r = channel.select({ inbox:case_receive() })
        if not r.ok then return nil, "inbox closed during mafia night" end
        local msg = r.value
        local tp = msg and msg:topic() or ""
        local raw = (msg and msg:payload() and msg:payload():data()) or {}

        if tp == "night.side_chat.reply" and partner_thinking then
            -- NPC partner replied. Commit chat line using the pre-reserved seq.
            local text = tostring(raw.text or "")
            local suggested_target_slot = raw.suggested_target_slot
            if text ~= "" and pending_reply_seq then
                local _, werr = chat.commit_chat_line(
                    game_id, round, partner_slot, text, chat_seq, "mafia_chat",
                    pending_reply_seq, "mafia")
                if werr then
                    logger:warn("[orchestrator] side_chat commit failed (partner)",
                        { err = tostring(werr) })
                end
            end
            table.insert(side_chat_history,
                { from = "partner", text = text, suggested_target_slot = suggested_target_slot })
            partner_thinking = false
            -- Suggestion is rendered SPA-side via the bubble's data payload; no extra event needed.

        elseif tp == "player.mafia_chat" and not partner_thinking then
            -- Human replied. Persist + dispatch next partner turn.
            -- Seq accounting (B2 fix per D-FLAG-01 + seq-authoritative invariant):
            --   * Human commit: reserve seq fresh (this is the dispatch site for the human).
            --   * Partner dispatch: reserve seq up-front and store in pending_reply_seq;
            --     the night.side_chat.reply handler reuses this exact value (no second +1).
            local text = tostring(raw.text or "")
            if text == "" then
                logger:debug("[orchestrator] empty mafia_chat from human; ignoring")
            else
                chat_seq[round] = (chat_seq[round] or 0) + 1
                local commit_seq = chat_seq[round]
                local _, werr = chat.commit_chat_line(
                    game_id, round, player_slot, text, chat_seq, "mafia_chat", commit_seq, "mafia")
                if werr then
                    logger:warn("[orchestrator] mafia_chat commit failed (human)",
                        { err = tostring(werr) })
                end
                table.insert(side_chat_history, { from = "human", text = text })

                -- Dispatch partner's next turn (only if still alive).
                -- Reserve seq NOW; the reply handler will commit at this exact value.
                if partner_alive then
                    chat_seq[round] = (chat_seq[round] or 0) + 1
                    local reserved = chat_seq[round]
                    pending_reply_seq = reserved
                    partner_thinking = true
                    process.send(npc_pids[partner_slot], "night.side_chat", {
                        round = round,
                        living_target_slots = living_target_slots,
                        living_target_names = living_target_names,
                        side_chat_history = side_chat_history,
                        preassigned_seq = reserved,
                    })
                end
            end

        elseif tp == "player.mafia_chat" and partner_thinking then
            -- Strict alternation guard (D-SC-03): human attempted to send while
            -- partner is generating. Drop. The SPA is supposed to disable input
            -- during partner_thinking but defense-in-depth here.
            logger:debug("[orchestrator] mafia_chat from human while partner thinking; dropping")

        elseif tp == "player.night_pick" then
            -- Validate target is in the living non-Mafia list. Reject otherwise (T-04-13).
            local target = tonumber(raw.target_slot)
            local valid = false
            for _, ts in ipairs(living_target_slots) do
                if tonumber(ts) == target then valid = true; break end
            end
            if not valid then
                logger:warn("[orchestrator] invalid night_pick target; ignoring",
                    { target_slot = tostring(target) })
            else
                victim_slot = target
                break
            end

        else
            -- Drop unrelated messages (stale day chat, cross-round, unknown).
        end
    end

    -- 6. Atomic SQL transaction (same shape as run_night_villager_auto / run_night_stub).
    local revealed_role = roles[victim_slot]
    local actor_slot = player_slot  -- The human is the picker.
    local json_ok, json_mod = pcall(require, "json")
    local reasoning_json
    local payload = {
        source = "mafia_human",
        human_slot = player_slot,
        target_slot = victim_slot,
        side_chat_history = side_chat_history,
        partner_alive = partner_alive,
    }
    if json_ok and json_mod and json_mod.encode then
        reasoning_json = json_mod.encode(payload)
    else
        reasoning_json = string.format(
            "{\"source\":\"mafia_human\",\"human_slot\":%d,\"target_slot\":%d,\"partner_alive\":%s}",
            player_slot, victim_slot, tostring(partner_alive))
    end
    reasoning_json = reasoning_json or "{}"

    local db, db_err = sql.get("app:db")
    if db_err or not db then return nil, "sql.get: " .. tostring(db_err) end
    local tx, tx_err = db:begin()
    if tx_err then db:release(); return nil, "begin: " .. tostring(tx_err) end
    local now_ts = time.now():unix()
    local ok, err = pcall(function()
        local _, e1 = tx:execute(
            "INSERT INTO night_actions (game_id, round, actor_slot, target_slot, created_at, reasoning_json) VALUES (?, ?, ?, ?, ?, ?)",
            { game_id, round, actor_slot, victim_slot, now_ts, reasoning_json }
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
    if not ok then tx:rollback(); db:release(); return nil, "tx failed: " .. tostring(err) end
    local _, commit_err = tx:commit()
    db:release()
    if commit_err then return nil, "commit: " .. tostring(commit_err) end

    alive[victim_slot] = false
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
    logger:info("[orchestrator] night resolved (mafia_human)", {
        round = round, victim_slot = victim_slot, actor_slot = actor_slot,
        partner_alive = partner_alive, side_chat_msgs = #side_chat_history,
    })
    return true, victim_slot
end

return {
    pick_night_victim = pick_night_victim,
    pick_night_actor = pick_night_actor,
    run_night_stub = run_night_stub,
    run_night_villager_auto = run_night_villager_auto,
    run_night_mafia_human = run_night_mafia_human,
}
