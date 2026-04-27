-- src/game/game_state.lua
-- Frame builder for game_state_changed events.
-- CLAUDE.md non-negotiable: `game_state_changed(phase="ended")` MUST carry `winner`
-- in the same atomic frame (no separate event). emit_game_state_changed preserves
-- the `winner` field on the phase="ended" branch (see line below).
-- Dead-player UI guard: alive_map[slot] is the canonical liveness field — no
-- parallel eliminated-slot table. build_gsc_roster respects this invariant.

local logger = require("logger"):named("game_state")
local pe     = require("pe")
local dt     = require("dev_telemetry")  -- for dev_mode() call in emit_game_state_changed

-- For a mafia at target_slot, return the OTHER mafia's slot.
-- Moved here from orchestrator.lua; also re-exported so orchestrator can alias it.
local function compute_partner_slot(roles, target_slot)
    if roles[target_slot] ~= "mafia" then return nil end
    for s = 1, 6 do
        if roles[s] == "mafia" and s ~= target_slot then return s end
    end
    return nil
end

-- Publish system/game_state_changed snapshot on every phase transition.
-- Takes explicit fields to avoid wippy-lint struct-shape union issues (same
-- pattern as run_night_stub / run_day_discussion).
-- CRITICAL: alive_map is state.alive — the canonical and SOLE liveness field
-- (Phase 2 invariant at :785). No parallel eliminated-slot table exists.
-- roles_map: state.roles. slot_persona_map: state.slot_persona (may be nil).
-- roster_names_map: state.roster_names (may be nil). player_sl: state.player_slot.
-- Build roster snapshot from the canonical Phase 2 alive/roles tables.
-- alive_map is state.alive — the SOLE liveness field. Role is revealed only
-- when alive_map[slot] == false (slot is dead), OR when reveal_all is true
-- (game-ended full reveal). No parallel eliminated-slot table.
local function build_gsc_roster(alive_map, roles_map, slot_persona_map,
                                 roster_names_map, player_sl, reveal_all)
    -- Use STRING keys for the outer map so the Wippy JSON serializer emits a
    -- JSON object, not a JSON array. A 1-indexed dense integer-keyed Lua table
    -- gets serialized as `[val1, val2, ...]` (0-indexed on the wire); the SPA's
    -- Object.entries then shifts all slot IDs down by 1, producing the "two
    -- 'You' chips" bug. String keys ("1", "2", ...) round-trip cleanly through
    -- parseInt on the SPA side.
    local roster = {}
    for slot = 1, 6 do
        local name
        if slot == player_sl then
            -- Prefer the player's chosen name from roster_names_map (the live
            -- orchestrator state). Fallback to "You" for legacy callers
            -- (e.g., test_driver) that do not populate roster_names_map.
            name = (roster_names_map and roster_names_map[slot]) or "You"
        else
            local sp = slot_persona_map and slot_persona_map[slot]
            if sp then
                name = sp.name or ("slot-" .. tostring(slot))
            elseif roster_names_map then
                name = roster_names_map[slot] or ("slot-" .. tostring(slot))
            else
                name = "slot-" .. tostring(slot)
            end
        end
        -- Use rawget to avoid wippy-lint's union-narrowing on table index
        -- (alive_map is state.alive: {[integer]:boolean}, canonical Phase 2 field).
        local is_alive = (rawget(alive_map, slot) == true)
        local revealed_role = nil
        if not is_alive or reveal_all then
            revealed_role = roles_map[slot]
        end
        -- Persona fields for NPC slots. Player slot has no persona (nil).
        -- voice_blurb is the first canonical utterance — a sample line of
        -- in-character dialogue for the "meet the cast" intro screen.
        local archetype_id, archetype_label, voice_blurb = nil, nil, nil
        local sp = slot_persona_map and slot_persona_map[slot]
        if sp then
            archetype_id = sp.archetype_id
            archetype_label = sp.archetype_label
            local utts = sp.canonical_utterances
            if type(utts) == "table" and utts[1] then
                voice_blurb = utts[1]
            end
        end
        roster[tostring(slot)] = {
            name = name,
            alive = is_alive,
            role = revealed_role,
            archetype_id = archetype_id,
            archetype_label = archetype_label,
            voice_blurb = voice_blurb,
        }
    end
    return roster
end

-- Publish system/game_state_changed on phase transitions (no elimination payload).
-- Takes explicit fields — avoids wippy-lint struct-shape union issues.
--
-- `winner` is only populated for the final phase="ended" emit so the SPA gets
-- phase and winner in one atomic frame (no race against the separate game.ended
-- event, which the EndGameBanner would otherwise render before winner lands).
local function emit_game_state_changed(game_id, alive_map, roles_map,
                                        slot_persona_map, roster_names_map,
                                        player_sl, phase, round, chat_locked, winner)
    local reveal_all = (phase == "ended")
    local roster = build_gsc_roster(alive_map, roles_map, slot_persona_map,
                                     roster_names_map, player_sl, reveal_all)
    local player_role = roles_map and roles_map[player_sl]
    local partner_slot = player_role == "mafia" and compute_partner_slot(roles_map, player_sl)
    local partner_name = partner_slot and slot_persona_map and
        slot_persona_map[partner_slot] and slot_persona_map[partner_slot].name
    -- Stamp partner's role onto their roster entry so the Mafia-human SPA can
    -- derive partnerAlive via roster scan (NightPicker.tsx:31). build_gsc_roster
    -- only reveals role for dead slots; alive partners need explicit stamping.
    -- Safe: partner_slot is non-nil only when player_role == "mafia" (D-09).
    if partner_slot and roster[tostring(partner_slot)] then
        roster[tostring(partner_slot)].role = roles_map[partner_slot]
    end
    pe.publish_event("system", "game_state_changed", "/" .. game_id, {
        phase = phase or "unknown",
        round = round or 0,
        dev_mode = dt.dev_mode(),   -- D-DEV-04: SPA reads this to render DEV chip
        alive = alive_map,
        roster = roster,
        player_slot = player_sl,
        player_role = player_role,
        partner_name = partner_name,
        game_id = game_id,
        chat_locked = chat_locked or false,
        winner = winner,
    })
end

-- Variant that carries last_eliminated payload (lynch/night-kill reveal).
-- chat_locked_flag: pass true during the vote-reveal animation window;
-- pass false when using this at the night-kill-to-day transition so the
-- SPA input is not disabled at the start of a fresh day.
local function emit_game_state_changed_elim(game_id, alive_map, roles_map,
                                             slot_persona_map, roster_names_map,
                                             player_sl, phase, round,
                                             elim_slot, elim_name, elim_role, elim_cause,
                                             chat_locked_flag)
    local reveal_all = (phase == "ended")
    local roster = build_gsc_roster(alive_map, roles_map, slot_persona_map,
                                     roster_names_map, player_sl, reveal_all)
    pe.publish_event("system", "game_state_changed", "/" .. game_id, {
        phase = phase or "unknown",
        round = round or 0,
        alive = alive_map,
        roster = roster,
        player_slot = player_sl,
        game_id = game_id,
        chat_locked = chat_locked_flag == nil and true or chat_locked_flag,
        last_eliminated = {
            slot = elim_slot, name = elim_name, role = elim_role, cause = elim_cause,
        },
    })
end

return {
    compute_partner_slot = compute_partner_slot,
    build_gsc_roster = build_gsc_roster,
    emit_game_state_changed = emit_game_state_changed,
    emit_game_state_changed_elim = emit_game_state_changed_elim,
}
