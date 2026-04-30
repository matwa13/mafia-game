-- src/npc/npc_stub.lua
-- Phase 2 Plan 02: deterministic stub NPC.
-- D-07: process.lua dynamically spawned by orchestrator.
-- D-08: args = { game_id, slot, role, mafia_partner_slot, parent_pid }
-- D-09: vote formula: vote_for_slot = ((from_slot + round) mod 6) + 1 (skip self/dead)
-- D-10: canned text: "slot-{N} day-{R}: {line}" with LINES[((round+slot-1) % #LINES)+1]
-- D-11: subscribe mafia.public (all), mafia.mafia (mafia only); no system_sub
-- D-13: on eliminated set state.dead = true; skip day.turn/vote.prompt after

local logger = require("logger"):named("npc_stub")
local events = require("events")
local time = require("time")
local channel = require("channel")

local LINES = {}
LINES[1] = "thinking..."
LINES[2] = "suspicious of slot-2"
LINES[3] = "quiet today"
LINES[4] = "following the evidence"
LINES[5] = "trust me on this"

-- D-10 formula; round is 1-indexed from orchestrator.
local function canned_text(slot, round)
    local idx = ((round + slot - 1) % #LINES) + 1
    return string.format("slot-%d day-%d: %s", slot, round, LINES[idx])
end

-- D-09 formula with self/dead skip.
-- state.dead set by eliminated inbox; alive_slots is set[slot]=true provided by orchestrator in vote.prompt payload.
-- NOTE: literal 6 below is the canonical participant count per D-02 (1 human slot 1 + 5 NPC slots 2..6).
local function pick_vote(from_slot, round, alive_slots, force_tie)
    if force_tie then
        -- force_tie: balance the NPC vote across a deterministic pair of
        -- target slots (A, B) drawn from the two lowest alive slots that are
        -- NOT slot 2 (the player driver-stub's default vote per orchestrator
        -- gather_votes) and NOT self. Each stub picks A if (from_slot % 2 == 0),
        -- else B (and flips the choice when the parity pick equals self).
        -- With 4 living NPC voters and evenly-parity-distributed slots, the
        -- tally lands on exactly 2 votes for A and 2 for B, producing a tie.
        local pair = {}
        for s = 1, 6 do
            if alive_slots[s] and s ~= from_slot and s ~= 2 then
                table.insert(pair, s)
                if #pair == 2 then break end
            end
        end
        if #pair == 2 then
            local pick = (from_slot % 2 == 0) and pair[1] or pair[2]
            return pick
        end
        if #pair == 1 then return pair[1] end
        for s = 1, 6 do
            if s ~= from_slot and alive_slots[s] then return s end
        end
        return from_slot
    end
    local target = ((from_slot + round) % 6) + 1  -- 6 = canonical participant count (D-02)
    for _ = 1, 6 do  -- 6 = canonical participant count (D-02)
        if target ~= from_slot and alive_slots[target] then
            return target
        end
        target = (target % 6) + 1
    end
    -- fallback: vote first alive non-self
    for s = 1, 6 do  -- 6 = canonical participant count (D-02)
        if s ~= from_slot and alive_slots[s] then return s end
    end
    return from_slot -- last resort; orchestrator tolerates self-vote
end

local function run(args)
    args = args or {}
    local game_id = args.game_id
    local slot = args.slot
    local role = args.role
    local mafia_partner_slot = args.mafia_partner_slot
    local parent_pid = args.parent_pid

    if not (game_id and slot and role and parent_pid) then
        logger:error("[npc_stub] missing required args", { args = tostring(args) })
        return
    end

    -- 1. Register BEFORE ack (Pitfall 1: race-free — orchestrator may lookup by name post-ack).
    local npc_name = string.format("npc:%s:%d", game_id, slot)
    local reg_ok, reg_err = process.registry.register(npc_name)
    if not reg_ok then
        logger:error("[npc_stub] registry.register failed", { npc = npc_name, err = tostring(reg_err) })
        return
    end

    -- 2. Subscribe BEFORE ack (Pitfall 1: no events missed between ack and subscribe).
    local public_sub = events.subscribe("mafia.public", "*")
    local mafia_sub = nil
    if role == "mafia" then
        mafia_sub = events.subscribe("mafia.mafia", "*")
    end
    local public_ch = public_sub and public_sub:channel() or nil
    local mafia_ch  = mafia_sub  and mafia_sub:channel()  or nil

    -- 3. Announce readiness AFTER register + subscribe (Pattern 1).
    process.send(parent_pid, "npc.ready", { slot = slot })
    logger:info("[npc_stub] ready", { npc = npc_name, role = role,
        mafia_partner_slot = mafia_partner_slot })

    -- 4. State: dead (D-13).
    local state = { dead = false }

    local inbox = process.inbox()
    local proc_ev = process.events()

    -- 5. Main loop.
    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if public_ch then table.insert(cases, public_ch:case_receive()) end
        if mafia_ch  then table.insert(cases, mafia_ch:case_receive())  end

        local r = channel.select(cases)
        if not r.ok then break end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local payload = {}
            local raw = msg:payload():data()
            if type(raw) == "table" then
                for k, v in pairs(raw) do payload[k] = v end
            end

            if topic == "day.turn" then
                -- payload: { round, pacing_ms (optional) }
                if state.dead then
                    -- D-13: dead stubs send empty turn (orchestrator drains promptly)
                    process.send(parent_pid, "chat.submit",
                        { slot = slot, text = "", round = payload.round, dead = true })
                else
                    if payload.pacing_ms then time.sleep(tostring(payload.pacing_ms) .. "ms") end
                    local text = canned_text(slot, payload.round or 0)
                    process.send(parent_pid, "chat.submit",
                        { slot = slot, text = text, round = payload.round })
                end

            elseif topic == "vote.prompt" then
                -- payload: { round, alive_slots (array or set), force_tie }
                if state.dead then
                    -- D-13: dead stubs do not vote; orchestrator tally treats missing as skip
                    process.send(parent_pid, "vote.cast",
                        { from_slot = slot, vote_for_slot = nil, reasoning = "dead",
                          round = payload.round, dead = true })
                else
                    -- normalize alive_slots to set[slot]=true
                    local alive = {}
                    if type(payload.alive_slots) == "table" then
                        for _, s in ipairs(payload.alive_slots) do alive[s] = true end
                        for k, v in pairs(payload.alive_slots) do
                            if type(k) == "number" and v then alive[k] = true end
                        end
                    end
                    local target = pick_vote(slot, payload.round or 0, alive, payload.force_tie == true)
                    process.send(parent_pid, "vote.cast",
                        { from_slot = slot, vote_for_slot = target,
                          reasoning = string.format("stub-formula r=%d", payload.round or 0),
                          round = payload.round })
                end

            elseif topic == "eliminated" then
                -- D-13: payload.slot == self => dead
                if payload.slot == slot then
                    state.dead = true
                    logger:info("[npc_stub] eliminated", { npc = npc_name, round = payload.round })
                end

            else
                logger:debug("[npc_stub] unhandled topic",
                    { npc = npc_name, topic = tostring(topic) })
            end

        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                -- Pitfall 9: close subs before returning so no subscription leaks.
                if public_sub then public_sub:close() end
                if mafia_sub  then mafia_sub:close()  end
                logger:info("[npc_stub] CANCEL; closing subs and exiting", { npc = npc_name })
                return
            end
            -- no EXIT/LINK_DOWN handling in stub (not a parent)

        elseif r.channel == public_ch then
            -- D-13: drop without inspection (stubs are role-blind to scope in Phase 2)

        elseif mafia_ch and r.channel == mafia_ch then
            -- D-13: drop without inspection

        end
    end

    -- normal-return subscription cleanup (defensive)
    if public_sub then public_sub:close() end
    if mafia_sub  then mafia_sub:close()  end
    return
end

return { run = run }
