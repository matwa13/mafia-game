-- src/npc/suspicion.lua
-- D-05 (Phase 6): Per-NPC suspicion state — rehydrate, persist, apply.
-- Non-negotiable: per-NPC suspicion state persisted to suspicion_snapshots at day-end
-- and rehydrated on NPC process restart (Phase 3 success criterion NPC-08).
-- Phase 3: suspicion is process-private, injected into dynamic tail on vote calls only.
-- SQL schema: suspicion_snapshots (game_id, round, slot, about_slot, value, created_at, npc_id, snapshot_json).
-- Migration 0003 added npc_id + snapshot_json; about_slot + value stay NOT NULL (0001 schema).

local logger = require("logger"):named("suspicion")
local sql    = require("sql")
local json   = require("json")
local time   = require("time")

local function rehydrate_suspicion(npc_id, game_id)
    local db, err = sql.get("app:db")
    if err then
        logger:warn("[npc] sql.get failed on rehydrate", { npc = npc_id, err = tostring(err) })
        return {}
    end
    local rows = db:query(
        "SELECT snapshot_json FROM suspicion_snapshots "
        .. "WHERE game_id = ? AND npc_id = ? "
        .. "ORDER BY round DESC LIMIT 1",
        { game_id, npc_id }
    )
    db:release()
    if rows and rows[1] then
        local snap_json = nil
        for k, v in pairs(rows[1]) do
            if k == "snapshot_json" then snap_json = v end
        end
        if snap_json then
            local decoded, derr = json.decode(tostring(snap_json))
            if decoded then return decoded end
            logger:warn("[npc] snapshot_json decode failed", { npc = npc_id, err = tostring(derr) })
        end
    end
    return {}
end

local function persist_suspicion_snapshot(npc_id, game_id, round, suspicion)
    local db, err = sql.get("app:db")
    if err then return nil, err end
    local json_blob, jerr = json.encode(suspicion or {})
    if jerr then db:release(); return nil, jerr end
    -- Migration 0003 added npc_id + snapshot_json; about_slot + value stay NOT NULL
    -- (0001 schema) so write placeholder 0 / 0.0 for legacy columns.
    local _, exec_err = db:execute(
        "INSERT INTO suspicion_snapshots "
        .. "(game_id, round, slot, about_slot, value, created_at, npc_id, snapshot_json) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        { game_id, round, 0, 0, 0.0, time.now():unix(), npc_id, json_blob }
    )
    db:release()
    if exec_err then return nil, exec_err end
    return true
end

local function apply_suspicion_updates(state, updates, reflection_notes)
    state.suspicion = state.suspicion or {}
    for name, delta in pairs(updates or {}) do
        local slot = state.name_to_slot[name]
        if slot and slot ~= state.slot then
            local current = state.suspicion[slot]
            local curr_value
            if type(current) == "table" then
                curr_value = current.value or 50
            else
                curr_value = current or 50
            end
            local new_value = curr_value + delta
            if new_value < 0 then new_value = 0 end
            if new_value > 100 then new_value = 100 end
            local note = reflection_notes and reflection_notes[name] or nil
            state.suspicion[slot] = { value = new_value, reflection_note = note }
        end
    end
end

return {
    rehydrate_suspicion        = rehydrate_suspicion,
    persist_suspicion_snapshot = persist_suspicion_snapshot,
    apply_suspicion_updates    = apply_suspicion_updates,
}
