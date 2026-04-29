-- src/game/day.lua
-- LOOP-04 (Day discussion round-robin): every alive NPC speaks an opening then a
-- follow-up; two-pass round-robin is the non-negotiable (CLAUDE.md Flow Invariant).
-- LOOP-05 (interjection): player.chat is committed live during NPC turns.
-- User-gated phase transition: day ends on player.advance_phase, NOT a wall-clock
-- timer. The previous wall-clock day_deadline was removed in Phase 3 polish.
-- Typing indicator (not token streaming): chunk events still flow for typing-state
-- propagation but are NOT rendered as a typewriter (Phase 3 polish invariant).
-- D-15 invariant: chat.line events emitted ONLY via chat.commit_chat_line (chat.lua).
-- Dead-player UI guard: alive[player_slot] checked before accepting player.chat.

local logger       = require("logger"):named("day")
local time         = require("time")
local sql          = require("sql")
local channel      = require("channel")
local json         = require("json")
local pe           = require("pe")
local chat         = require("chat")
local game_state   = require("game_state")
local dev_telemetry = require("dev_telemetry")

-- Convenience aliases matching orchestrator.lua convention.
local append_dev_event        = dev_telemetry.append_dev_event
local emit_game_state_changed = game_state.emit_game_state_changed

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
--
-- Uses `time.after(day_duration)` for the day-level deadline (one-shot,
-- created ONCE per phase — Pitfall 2). Per-speaker caps are fresh per iteration.
-- day_duration / pacing_ms are inlined at call site (D-DEV-03: stale constants deleted).
-- All in-repo deadlines use `time.after(...)`. Authority: src/probes/probe.lua,
-- src/npc/test_driver.lua, src/npc/npc_test.lua.
local function run_day_discussion(game_id, round, alive, player_slot, npc_pids,
                                  day_duration, pacing_ms, dev, chat_seq, inbox,
                                  roles, slot_persona, roster_names)
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
        if type(npc_pid) ~= "string" then
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
                                local _, write_err = chat.commit_npc_chat_with_delay(
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
    -- WR-05 fix (Phase 10): publish the vote-phase snapshot here so the orchestrator
    -- no longer emits a second contradicting frame with chat_locked=false. Mirrors
    -- run_day_discussion_streaming's terminal emit. Guarded on roles/slot_persona/
    -- roster_names being supplied because legacy Phase-2 stub callers may invoke
    -- this function without them; in that case we skip the snapshot (no regression).
    if roles and slot_persona and roster_names then
        emit_game_state_changed(game_id, alive, roles, slot_persona,
            roster_names, player_slot, "vote", round, true)
    end
    logger:info("[orchestrator] day complete", { round = round, reason = reason })
    return true, nil
end

-- Phase 3: run_day_discussion_streaming.
-- Same outer contract as run_day_discussion but:
--   - each living NPC gets up to 2 messages (1st mandatory, 2nd optional)
--   - races per-speaker deadline + day-level deadline + interjection + streaming chunks
--   - dispatches chat.stream.chunk, chat.submit, chat.decline, player.chat, abort.turn
-- Takes explicit state fields (rng_seed, roles, slot_persona, roster_names) to avoid
-- wippy-lint struct-shape union issues (same pattern as run_night_stub).
local function run_day_discussion_streaming(game_id, round, alive, player_slot, npc_pids,
                                            dev_mode_flag, chat_seq, inbox,
                                            rng_seed, roles, slot_persona, roster_names,
                                            dev_state)
    -- Day discussion is now USER-DRIVEN: every living NPC speaks both
    -- mandatory turns in sequence, and the phase only transitions to VOTE
    -- when either (a) all NPCs have finished their 2 turns, or (b) the
    -- user clicks "End discussion →" in the SPA, which sends
    -- `game_advance_phase` → `player.advance_phase` into this inbox.
    --
    -- The previous wall-clock day_deadline was removed because it could
    -- cut off NPCs mid-round before they'd spoken. Per-speaker cap stays —
    -- it only protects against a hung/stuck LLM call on a single turn
    -- (≈12s dev / 25s prod).
    local per_speaker_s = dev_mode_flag and "12s" or "25s"

    -- Drain any pre-queued messages (e.g., stale player.chat from night phase).
    -- run_night_stub does not read the inbox, so if the UI lets the human type
    -- during night, those messages sit in the orchestrator's inbox and would
    -- be committed at seq=1 here — rendering above all NPC messages in the
    -- SPA transcript. The frontend disables the input during non-day phases
    -- as the primary guard; this is a belt-and-suspenders sweep.
    local drain_ch = time.after("10ms")
    while true do
        local r = channel.select({ inbox:case_receive(), drain_ch:case_receive() })
        if not r.ok or r.channel == drain_ch then break end
        -- Discard (do not commit, do not re-publish).
    end

    -- Randomized-start round-robin over alive NPC slots (exclude player).
    math.randomseed(math.floor((tonumber(rng_seed) or 0) + (tonumber(round) or 0) * 1000))
    local living_npc_slots = {}
    for slot = 1, 6 do
        if alive[slot] and slot ~= player_slot then
            table.insert(living_npc_slots, slot)
        end
    end
    -- Fisher-Yates
    for i = #living_npc_slots, 2, -1 do
        local j = math.random(i)
        living_npc_slots[i], living_npc_slots[j] = living_npc_slots[j], living_npc_slots[i]
    end

    -- User-driven advance flag. Set true when a `player.advance_phase`
    -- message lands in the orchestrator's inbox during day discussion.
    local advance_requested = false

    -- Two-pass round-robin: all living NPCs do their opening first
    -- (msg_index=1), then all living NPCs do their follow-up (msg_index=2).
    -- This keeps every speaker in rotation instead of letting one NPC
    -- monopolize both turns before the next speaker begins.
    for msg_index = 1, 2 do
        local is_mandatory = (msg_index == 1)

        for _, slot in ipairs(living_npc_slots) do
            if not alive[slot] then
                goto continue_slot
            end
            local npc_pid = npc_pids[slot]
            if type(npc_pid) ~= "string" then
                goto continue_slot
            end

            -- RESERVE a seq for this NPC turn BEFORE sending day.turn. Any
            -- player.chat that lands during the turn will commit with a
            -- higher seq, so when the SPA sorts messages by seq the NPC's
            -- bubble is guaranteed to render above the user's interjection.
            chat_seq[round] = (chat_seq[round] or 0) + 1
            local reserved_seq = chat_seq[round]

            -- Tell the SPA to show a "{name} is typing..." bubble at this
            -- reserved seq slot. The chat.line commit (or typing.ended on
            -- a decline/abort) will clear it.
            pe.publish_event("public", "typing.started", "/" .. game_id, {
                round = round, from_slot = slot, seq = reserved_seq,
            })
            if dev_state then append_dev_event(dev_state, "public", "typing.started", "/" .. game_id) end

            process.send(npc_pid, "day.turn", {
                round = round,
                msg_index = msg_index,
                is_mandatory = is_mandatory,
            })

            local per_speaker_ch = time.after(per_speaker_s)
            local done_this_msg = false
            local turn_committed = false
            while not done_this_msg do
                local r = channel.select({
                    inbox:case_receive(),
                    per_speaker_ch:case_receive(),
                })

                if r.channel == inbox then
                    local msg = r.value
                    local tp  = msg and msg:topic() or ""
                    local raw = (msg and msg:payload() and msg:payload():data()) or {}

                    if tp == "chat.submit" and raw.from_slot == slot and raw.round == round then
                        -- Dead-NPC guard: if alive[slot] flipped false between
                        -- day.turn dispatch and reply (shouldn't happen during
                        -- day — belt and suspenders), drop the submit.
                        if not alive[slot] then
                            logger:warn("[orchestrator] dropping chat.submit from dead slot",
                                { slot = slot, round = round })
                            done_this_msg = true
                        else
                            local kind = raw.kind or "npc"
                            -- Use the reserved seq so this NPC lands at its
                            -- pre-allocated slot regardless of intervening user
                            -- interjections (which took higher seqs).
                            local _, werr = chat.commit_npc_chat_with_delay(game_id, round, slot,
                                tostring(raw.text or ""), chat_seq, kind, reserved_seq)
                            if werr then
                                logger:error("[orchestrator] commit_chat_line failed",
                                    { slot = slot, err = tostring(werr) })
                            end
                            turn_committed = true
                            done_this_msg = true
                        end

                    elseif tp == "chat.decline" and raw.from_slot == slot and raw.round == round then
                        logger:info("[orchestrator] chat.decline", {
                            slot = slot, msg_index = msg_index, reason = raw.reason,
                        })
                        done_this_msg = true

                    elseif tp == "player.chat" then
                        local text = tostring(raw.text or "")
                        local from = raw.from_slot or player_slot
                        -- Dead-player guard: eliminated humans cannot chat.
                        -- Frontend already hides the input; this is backend
                        -- defense-in-depth against spoofed/stale frames.
                        if text ~= "" and alive[from] then
                            -- Commit immediately. User gets the next auto-
                            -- incremented seq (which is > reserved_seq), so
                            -- the SPA's seq-sorted render puts the user's
                            -- bubble BELOW this NPC's (still-pending) bubble.
                            local _, werr = chat.commit_player_chat(game_id, round,
                                from, text, chat_seq)
                            if werr then
                                logger:warn("[orchestrator] commit_player_chat failed",
                                    { err = tostring(werr) })
                            end
                            -- Do NOT abort the NPC turn — let it finish.
                        elseif text ~= "" then
                            logger:info("[orchestrator] dropping player.chat from dead slot",
                                { from_slot = from, round = round })
                        end

                    elseif tp == "player.advance_phase" then
                        -- User clicked "End discussion →". Abort the in-flight
                        -- NPC turn and flag both loops to exit. We exit this
                        -- inner while via done_this_msg = true; the outer
                        -- loops exit via the advance_requested checks.
                        --
                        -- Round match: a stale advance_phase from a previous
                        -- round's gate (e.g. the user double-clicked Start
                        -- Next Day before the client rerendered) must NOT
                        -- cut this round's discussion short — that would be
                        -- auto-advance.
                        local adv_round = tonumber(raw.round)
                        if adv_round == round then
                            logger:info("[orchestrator] player.advance_phase received",
                                { slot = slot, msg_index = msg_index })
                            advance_requested = true
                            process.send(npc_pid, "abort.turn", {})
                            done_this_msg = true
                        end

                    end
                    -- Ignore other topics during day turn.

                elseif r.channel == per_speaker_ch then
                    logger:warn("[orchestrator] per-speaker cap hit",
                        { slot = slot, msg_index = msg_index })
                    process.send(npc_pid, "abort.turn", {})
                    done_this_msg = true
                end
            end

            -- If the turn ended WITHOUT a commit (decline / per-speaker cap /
            -- user advance), tell the SPA to clear the typing bubble. On the
            -- commit path, chat.line already implicitly clears it on the SPA.
            if not turn_committed then
                pe.publish_event("public", "typing.ended", "/" .. game_id, {
                    round = round, from_slot = slot, seq = reserved_seq,
                })
                if dev_state then append_dev_event(dev_state, "public", "typing.ended", "/" .. game_id) end
            end

            if advance_requested then break end
            ::continue_slot::
        end

        if advance_requested then break end
    end

    -- If all NPCs spoke naturally (no user interruption), DO NOT auto-advance.
    -- Publish `day.discussion_ready` so the SPA can enable the "End discussion"
    -- button, then block until the user clicks it. The player can keep typing
    -- interjections during this wait; only `player.advance_phase` unblocks us.
    if not advance_requested then
        pe.publish_event("system", "day.discussion_ready", "/" .. game_id, {
            round = round,
        })
        if dev_state then append_dev_event(dev_state, "system", "day.discussion_ready", "/" .. game_id) end
        logger:info("[orchestrator] discussion complete, awaiting user advance",
            { round = round })
        while not advance_requested do
            local r = channel.select({ inbox:case_receive() })
            if not r.ok then break end
            local msg = r.value
            local tp = msg and msg:topic() or ""
            local raw = (msg and msg:payload() and msg:payload():data()) or {}
            if tp == "player.advance_phase" then
                -- Round match: cross-round stale advance_phase must not
                -- slip through this gate either.
                local adv_round = tonumber(raw.round)
                if adv_round == round then
                    advance_requested = true
                end
            elseif tp == "player.chat" then
                -- Commit late interjections — NPCs won't reply any more, but
                -- the message still belongs in the transcript. Dead-player
                -- guard: skip if the sender has been eliminated.
                local text = tostring(raw.text or "")
                local from = raw.from_slot or player_slot
                if text ~= "" and alive[from] then
                    local _, werr = chat.commit_player_chat(game_id, round,
                        from, text, chat_seq)
                    if werr then
                        logger:warn("[orchestrator] commit_player_chat failed",
                            { err = tostring(werr) })
                    end
                elseif text ~= "" then
                    logger:info("[orchestrator] dropping late player.chat from dead slot",
                        { from_slot = from, round = round })
                end
            end
            -- drop all other inbox topics during this wait
        end
    end

    -- Drain remaining chunks ~500ms so late submit/chunk don't leak into vote phase.
    local drain_end = time.after("500ms")
    while true do
        local r = channel.select({ inbox:case_receive(), drain_end:case_receive() })
        if not r.ok or r.channel == drain_end then break end
    end

    pe.publish_event("system", "chat_locked", "/" .. game_id, {
        round = round,
        reason = advance_requested and "user_advance" or "all_spoken",
    })
    if dev_state then append_dev_event(dev_state, "system", "chat_locked", "/" .. game_id) end
    emit_game_state_changed(game_id, alive, roles, slot_persona,
        roster_names, player_slot, "vote", round, true)
    if dev_state then append_dev_event(dev_state, "system", "game_state_changed", "/" .. game_id) end
    return true, nil
end

return {
    speaking_order = speaking_order,
    run_day_discussion = run_day_discussion,
    run_day_discussion_streaming = run_day_discussion_streaming,
}
