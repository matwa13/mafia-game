-- src/npc/npc.lua — Phase 3 real-LLM NPC.
-- Template: src/npc/npc_test.lua (Phase 1) + parameterized persona per
-- CONTEXT.md D-01..D-04 + SHA256 tripwire (Phase 1 D-15 inherited).
-- Spawned dynamically by orchestrator (not auto_start). Name-registers
-- as "npc:<game_id>:<slot>" before subscribing/ready to avoid missed events.
-- Phase 6 (Cut 5): shrunk to Pattern B shell — main_loop + run only.
-- All helper fns extracted to: prompts, turn_chat, turn_vote, turn_night_pick,
-- turn_side_chat, turn_last_words, errors, suspicion, event_log.

local logger          = require("logger"):named("npc")
local events          = require("events")
local time            = require("time")
local sql             = require("sql")
local json            = require("json")
local hash            = require("hash")
local pe              = require("pe")
local persona         = require("persona")
local channel         = require("channel")
local prompts         = require("prompts")
local turn_chat       = require("turn_chat")
local turn_vote       = require("turn_vote")
local turn_night_pick = require("turn_night_pick")
local turn_side_chat  = require("turn_side_chat")
local turn_last_words = require("turn_last_words")
local errors          = require("errors")
local suspicion       = require("suspicion")
local event_log       = require("event_log")

-- Section L: main loop + boot -----------------------------------------------

local function main_loop(state, public_sub, mafia_sub, system_sub,
                         public_ch, mafia_ch, system_ch, proc_ev)
    local inbox = process.inbox()

    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if public_ch then table.insert(cases, public_ch:case_receive()) end
        if mafia_ch  then table.insert(cases, mafia_ch:case_receive())  end
        if system_ch then table.insert(cases, system_ch:case_receive()) end

        local r = channel.select(cases)
        if not r.ok then
            if public_sub then public_sub:close() end
            if mafia_sub  then mafia_sub:close()  end
            if system_sub then system_sub:close() end
            return
        end

        if r.channel == inbox then
            local msg = r.value
            local tp = msg:topic()
            local raw = msg:payload():data() or {}

            if tp == "day.turn" then
                if state.dead then
                    logger:info("[npc] dead; skipping day.turn", { npc = state.npc_id })
                else
                    local turn_round = 0
                    local is_mandatory = true
                    for k, v in pairs(raw) do
                        if k == "round" then turn_round = v end
                        if k == "is_mandatory" then is_mandatory = (v ~= false) end
                    end
                    turn_chat.run_chat_turn(state, turn_round, is_mandatory)
                end

            elseif tp == "vote.prompt" then
                if state.dead then
                    logger:info("[npc] dead; skipping vote.prompt", { npc = state.npc_id })
                    local vote_round = 0
                    for k, v in pairs(raw) do
                        if k == "round" then vote_round = v end
                    end
                    process.send(state.parent_pid, "vote.cast", {
                        from_slot = state.slot, vote_for_slot = nil,
                        reasoning = "dead", round = vote_round,
                    })
                else
                    local vote_round = 0
                    for k, v in pairs(raw) do
                        if k == "round" then vote_round = v end
                    end
                    turn_vote.run_vote_turn(state, vote_round)
                end

            elseif tp == "night.pick" then
                if state.dead then
                    logger:info("[npc] dead; skipping night.pick", { npc = state.npc_id })
                elseif state.role ~= "mafia" then
                    logger:warn("[npc] non-mafia received night.pick; dropping",
                        { npc = state.npc_id, role = state.role })
                else
                    turn_night_pick.run_night_pick(state, raw)
                end

            elseif tp == "night.side_chat" then
                if state.dead then
                    logger:info("[npc] dead; skipping night.side_chat", { npc = state.npc_id })
                elseif state.role ~= "mafia" then
                    logger:warn("[npc] non-mafia received night.side_chat; dropping",
                        { npc = state.npc_id, role = state.role })
                else
                    turn_side_chat.run_night_side_chat(state, raw)
                end

            elseif tp == "dev.snapshot.request" then
                -- D-DP-05/D-DP-06: reply with per-card telemetry. No LLM call; non-blocking.
                -- NPCs never subscribe to "mafia.dev" — this handler only fires on unicast
                -- process.send from the orchestrator (firewall intact per Pitfall 4).
                --
                -- suspicion table needs two transforms before it can cross the
                -- WS as JSON: (1) integer slot keys → strings, otherwise the
                -- http.ws transcoder rejects sparse arrays and closes the WS;
                -- (2) {value, reflection_note} → {score, reasons} to match the
                -- SPA's DevNpcSnapshot.suspicion shape (DevNpcCard reads
                -- entry.score).
                local suspicion_out = {}
                for k, v in pairs(state.suspicion or {}) do
                    if type(v) == "table" then
                        suspicion_out[tostring(k)] = {
                            score   = v.value,
                            reasons = (type(v.reflection_note) == "string" and v.reflection_note ~= "")
                                      and { v.reflection_note } or nil,
                        }
                    end
                end
                process.send(state.parent_pid, "dev.snapshot.reply", {
                    slot           = state.slot,
                    role           = state.role,
                    alive          = state.dead == false,
                    archetype      = state.persona_args and state.persona_args.archetype or nil,
                    name           = state.persona_args and state.persona_args.name or nil,
                    suspicion      = suspicion_out,
                    stable_sha     = state.stable_hash,
                    dynamic_tail   = state.last_dynamic_tail,
                    last_llm_error = state.last_llm_error,
                    last_vote      = state.last_vote,
                    last_pick      = state.last_pick,
                })

            elseif tp == "eliminated" then
                local elim_slot = nil
                local elim_round = 0
                local request_lw = false
                for k, v in pairs(raw) do
                    if k == "slot" then elim_slot = v end
                    if k == "round" then elim_round = v end
                    if k == "request_last_words" then request_lw = (v == true) end
                end
                if elim_slot == state.slot then
                    state.dead = true
                    logger:info("[npc] eliminated", { npc = state.npc_id, round = elim_round })
                    if request_lw then
                        local text, err = turn_last_words.run_last_words(state, elim_round)
                        if text and text ~= "" then
                            process.send(state.parent_pid, "chat.submit", {
                                from_slot = state.slot, round = elim_round,
                                text = text, kind = "last_words",
                            })
                        else
                            logger:warn("[npc] last_words failed", {
                                npc = state.npc_id, err = tostring(err),
                            })
                        end
                    end
                    -- DO NOT return — orchestrator sends CANCEL; main_loop CANCEL branch handles exit.
                end

            else
                logger:debug("[npc] unhandled inbox topic", {
                    npc = state.npc_id, topic = tostring(tp),
                })
            end

        elseif r.channel == proc_ev then
            local event = r.value
            if event and event.kind == process.event.CANCEL then
                if public_sub then public_sub:close() end
                if mafia_sub  then mafia_sub:close()  end
                if system_sub then system_sub:close() end
                logger:info("[npc] CANCEL; exiting", { npc = state.npc_id })
                return
            end

        elseif r.channel == public_ch then
            -- Accumulate events into log for prompt context (NPC-06).
            -- Skip chat.chunk — streaming chunks are transient and each
            -- chunk would otherwise become a log entry, flooding the
            -- prompt. Only chat.line (the committed bubble) is narrative.
            local kind, data = event_log.unpack_event(r.value)
            if kind and kind ~= "chat.chunk" then
                event_log.append_event(state, event_log.event_to_log_entry(kind, data))
            end

        elseif mafia_ch and r.channel == mafia_ch then
            local kind, data = event_log.unpack_event(r.value)
            if kind then
                event_log.append_event(state, event_log.event_to_log_entry(kind, data))
            end

        elseif system_ch and r.channel == system_ch then
            -- System scope carries many orchestration events
            -- (game_state_changed, chat_locked, npc_turn_skipped). Only
            -- the genuinely narrative ones belong in the NPC's prompt:
            -- night.resolved tells them someone was killed at night,
            -- and vote.tied tells them the vote failed to lynch.
            local kind, data = event_log.unpack_event(r.value)
            if kind == "night.resolved" or kind == "vote.tied" then
                event_log.append_event(state, event_log.event_to_log_entry(kind, data))
            end

        end
    end
end

local function run(args)
    args = args or {}
    local game_id = args.game_id
    local slot = args.slot
    local role = args.role
    local parent_pid = args.parent_pid

    if not (game_id and slot and role and parent_pid) then
        logger:error("[npc] missing required args", { args = tostring(args) })
        return
    end

    local NPC_ID = string.format("npc:%s:%d", game_id, slot)

    -- 1. Build stable persona block from spawn args (parameterized per D-01/D-03).
    local persona_args = {
        archetype            = args.archetype or persona.FIXTURE.archetype,
        name                 = args.name or persona.FIXTURE.name,
        voice_quirk          = args.voice_quirk or persona.FIXTURE.voice,
        canonical_utterances = args.canonical_utterances or {},
        role                 = role,
        partner_name         = args.mafia_partner_name,
        roster_names         = args.roster_names or {},
        rules_text           = persona.RULES,
    }
    local stable_block = tostring(persona.render_stable_block(persona_args))
    local stable_hash = hash.sha256(stable_block)
    -- Cache-minimum diagnostic (Pitfall 1 — >=4096 tokens on haiku-4-5).
    -- Token approximation: ~4 chars/token.
    logger:info("[npc] stable_block built", {
        npc = NPC_ID, hash = stable_hash, bytes = #stable_block,
        tokens_est = math.floor(#stable_block / 4),
    })
    if (#stable_block / 4) < 4096 then
        logger:warn("[npc] stable_block under 4096-token cache minimum", {
            npc = NPC_ID, tokens_est = math.floor(#stable_block / 4),
        })
    end

    -- 2. Registry register BEFORE subscribe (Pitfall 1).
    local reg_ok, reg_err = process.registry.register(NPC_ID)
    if not reg_ok then
        logger:error("[npc] registry.register failed", { npc = NPC_ID, err = tostring(reg_err) })
        return
    end

    -- 3. Subscribe BEFORE ready-ack.
    -- scope_allowed permits `system` for both roles (villager + mafia),
    -- so we subscribe to mafia.system for night.resolved / vote.tied
    -- narrative events. The main_loop filters the specific kinds it cares
    -- about (see system_ch handler) to avoid polluting the prompt with
    -- game_state_changed / chat_locked chatter.
    local public_sub = events.subscribe("mafia.public", "*")
    local system_sub = events.subscribe("mafia.system", "*")
    local mafia_sub = nil
    if role == "mafia" then
        mafia_sub = events.subscribe("mafia.mafia", "*")
    end
    local public_ch = public_sub and public_sub:channel() or nil
    local mafia_ch  = mafia_sub  and mafia_sub:channel()  or nil
    local system_ch = system_sub and system_sub:channel() or nil
    local proc_ev = process.events()

    -- 4. Rehydrate suspicion from last snapshot (NPC-08 restart survival).
    local susp = suspicion.rehydrate_suspicion(NPC_ID, game_id)

    -- 5. Ready handshake.
    process.send(parent_pid, "npc.ready", { slot = slot })
    logger:info("[npc] ready", { npc = NPC_ID, role = role })

    -- 6. State table carried through handlers.
    local state = {
        npc_id       = NPC_ID,
        game_id      = game_id,
        slot         = slot,
        role         = role,
        parent_pid   = parent_pid,
        stable_block = stable_block,
        stable_hash  = stable_hash,
        persona_args = persona_args,
        name         = args.name,
        name_to_slot = args.name_to_slot or {},
        roster_names = args.roster_names or {},
        suspicion    = susp,
        event_log    = {},
        roster       = {},
        round        = 0,
        dead         = false,
        -- D-DP-06: dev telemetry fields — populated by vote/pick/error handlers.
        last_llm_error    = nil,
        last_vote         = nil,
        last_pick         = nil,
        last_dynamic_tail = nil,
    }

    -- 7. Main loop.
    main_loop(state, public_sub, mafia_sub, system_sub,
              public_ch, mafia_ch, system_ch, proc_ev)
end

return { run = run }
