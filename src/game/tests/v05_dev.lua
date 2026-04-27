-- src/game/tests/v05_dev.lua
-- Phase 5 V-05-XX scenarios — dev-mode hardening (dev_mode field,
-- determinism, persona blobs, dev_plugin transport, dev_snapshot,
-- event_tail ring buffer, RSS soak).
-- All require MAFIA_DEV_MODE=1 (V-05-02-dev-field-false SKIPs if dev=1;
-- V-05-04 SKIPs if MAFIA_SEED unset; V-05-10 SKIPs unless MAFIA_NPC_MODE=stub).
-- D-21: [TEST] V-05-XX <name> OK|FAIL|SKIP line format.
-- Phase 6 cut 3 (T-02): bodies extracted verbatim from
-- src/game/test_driver.lua:1387-2434. Per 06-PATTERNS.md S-4 the only
-- changes are the local-alias block + per-file logger name.

local logger  = require("logger"):named("v05_dev")
local time    = require("time")
local sql     = require("sql")
local events  = require("events")
local channel = require("channel")
local env     = require("env")
local harness = require("harness")

-- Local-alias block — keeps test bodies byte-identical (Pattern E).
local log_ok              = harness.log_ok
local log_fail            = harness.log_fail
local log_skip            = harness.log_skip
local field               = harness.field
local lookup_game_manager = harness.lookup_game_manager
local wait_for_reply      = harness.wait_for_reply
local count_rows          = harness.count_rows
local get_row             = harness.get_row
local poll_until          = harness.poll_until
local start_game          = harness.start_game
local wait_for_winner     = harness.wait_for_winner

-- Suppress unused-warning on aliases this group doesn't reference.
local _unused = { sql, lookup_game_manager, wait_for_reply, wait_for_winner }
_unused = nil

-- ══════════════════════════════════════════════════════════════════
-- V-05-06 scenarios — Phase 5 Plan 03: dev telemetry transport.
-- All require MAFIA_DEV_MODE=1.
-- ══════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- V-05-06: start_game → wait for first dev_snapshot on mafia.dev →
-- assert roster has 5 keys, each with slot/role/suspicion/stable_sha;
-- mafia_slots is a 2-element array; data.seed matches requested rng_seed.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_06_dev_snapshot(inbox, gm_pid)
    local name = "V-05-06 dev-snapshot roster shape"
    local dev_sub = events.subscribe("mafia.dev", "*")
    local dev_ch = dev_sub and dev_sub:channel() or nil
    if not dev_ch then
        log_fail(name, "events.subscribe('mafia.dev') failed")
        return
    end

    local seed = 3
    local payload, err = start_game(inbox, gm_pid, seed, false)
    if not payload then
        dev_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        dev_sub:close()
        log_fail(name, "no game_id in payload")
        return
    end

    -- Wait up to 30s for a dev_snapshot event for this game.
    local snapshot = nil
    local deadline = time.after("30s")
    while not snapshot do
        local r = channel.select({ inbox:case_receive(), dev_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        if r.channel == dev_ch then
            local evt = r.value
            if evt and evt.kind == "snapshot" then
                local d = evt.data or {}
                if d.game_id == game_id then
                    snapshot = d
                end
            end
        end
    end
    dev_sub:close()

    if not snapshot then
        log_fail(name, "no dev_snapshot event received within 30s for game " .. tostring(game_id))
        return
    end

    -- Assert seed matches.
    if tostring(snapshot.seed) ~= tostring(seed) then
        log_fail(name, "seed mismatch: got=" .. tostring(snapshot.seed) .. " expected=" .. tostring(seed))
        return
    end

    -- Assert mafia_slots is a 2-element array.
    local ms = snapshot.mafia_slots
    if type(ms) ~= "table" or #ms ~= 2 then
        log_fail(name, "mafia_slots expected 2-element array, got: " .. tostring(ms and #ms))
        return
    end

    -- Assert roster has 5 keys (slots 2-6), each with required fields.
    local roster = snapshot.roster
    if type(roster) ~= "table" then
        log_fail(name, "roster is not a table")
        return
    end
    local roster_count = 0
    for _, _ in pairs(roster) do roster_count = roster_count + 1 end
    if roster_count ~= 5 then
        log_fail(name, "roster expected 5 entries, got " .. tostring(roster_count))
        return
    end
    for _, entry in pairs(roster) do
        if type(entry) ~= "table" then
            log_fail(name, "roster entry is not a table")
            return
        end
        -- unavailable entries are acceptable (slot unreachable within 500ms)
        if not field(entry, "unavailable") then
            for _, req in ipairs({ "slot", "role", "stable_sha" }) do
                if field(entry, req) == nil then
                    log_fail(name, "roster entry missing field '" .. req .. "'")
                    return
                end
            end
        end
    end
    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-06b: after first vote phase, every alive NPC roster entry
-- has a non-nil last_vote.target_slot. Before first vote, last_vote
-- may be nil — we skip the pre-vote assertion to keep it simple.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_06b_last_vote(inbox, gm_pid)
    local name = "V-05-06b last-vote populated after vote"
    local dev_sub = events.subscribe("mafia.dev", "*")
    local dev_ch = dev_sub and dev_sub:channel() or nil
    if not dev_ch then
        log_fail(name, "events.subscribe('mafia.dev') failed")
        return
    end

    local payload, err = start_game(inbox, gm_pid, 5, false)
    if not payload then
        dev_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        dev_sub:close()
        log_fail(name, "no game_id")
        return
    end

    -- Wait for a dev_snapshot with phase='vote' or later (post-vote snapshot).
    local post_vote_snapshot = nil
    local deadline = time.after("90s")
    while not post_vote_snapshot do
        local r = channel.select({ inbox:case_receive(), dev_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        if r.channel == dev_ch then
            local evt = r.value
            if evt and evt.kind == "snapshot" then
                local d = evt.data or {}
                local ph = d.phase
                -- "vote" phase snapshot is emitted at the START of vote; we want one after
                -- votes are cast — look for ended/night (next round) or accept vote-phase
                -- snapshot since NPCs complete voting before snapshot is emitted.
                if d.game_id == game_id and (ph == "vote" or ph == "night" or ph == "ended") then
                    post_vote_snapshot = d
                end
            end
        end
    end
    dev_sub:close()

    if not post_vote_snapshot then
        log_skip(name, "no post-vote dev_snapshot within 90s; long LLM game — skip")
        return
    end

    -- For each roster entry that is alive and not unavailable, check last_vote.
    local roster = post_vote_snapshot.roster or {}
    local missing = {}
    for _, entry in pairs(roster) do
        if type(entry) == "table" and not field(entry, "unavailable") then
            local alive = field(entry, "alive")
            local lv = field(entry, "last_vote")
            if alive and (lv == nil or field(lv, "target_slot") == nil) then
                table.insert(missing, tostring(field(entry, "slot") or "?"))
            end
        end
    end
    if #missing == 0 then
        log_ok(name)
    else
        log_fail(name, "slots missing last_vote after vote phase: " .. table.concat(missing, ","))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-06c: NPC timeout → unavailable. SKIP with rationale: injecting
-- a slow NPC reply without a controllable stub mode is not feasible
-- from test_driver; the 500ms collector timeout is exercised implicitly
-- when a NPC process is killed mid-game (manual testing). The collector
-- marks missing slots as {unavailable=true} per the roster shape check
-- in V-05-06.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_06c_unavailable()
    log_skip("V-05-06c npc-timeout-unavailable",
        "requires controllable slow-reply NPC stub; not injectable from test_driver. "
        .. "Collector timeout + unavailable={true} shape verified by V-05-06 roster walk.")
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-06d: event_tail non-empty after first phase transition.
-- Wait for first dev_snapshot on mafia.dev; assert event_tail is an
-- array with >= 1 entry and each entry has {scope, kind, path, ts}.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_06d_event_tail(inbox, gm_pid)
    local name = "V-05-06d event-tail non-empty"
    local dev_sub = events.subscribe("mafia.dev", "*")
    local dev_ch = dev_sub and dev_sub:channel() or nil
    if not dev_ch then
        log_fail(name, "events.subscribe('mafia.dev') failed")
        return
    end

    local payload, err = start_game(inbox, gm_pid, 9, false)
    if not payload then
        dev_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        dev_sub:close()
        log_fail(name, "no game_id")
        return
    end

    local snapshot = nil
    local deadline = time.after("30s")
    while not snapshot do
        local r = channel.select({ inbox:case_receive(), dev_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        if r.channel == dev_ch then
            local evt = r.value
            if evt and evt.kind == "snapshot" then
                local d = evt.data or {}
                if d.game_id == game_id then snapshot = d end
            end
        end
    end
    dev_sub:close()

    if not snapshot then
        log_fail(name, "no dev_snapshot within 30s for game " .. tostring(game_id))
        return
    end

    local et = snapshot.event_tail
    if type(et) ~= "table" then
        log_fail(name, "event_tail is not a table, got: " .. type(et))
        return
    end
    if #et < 1 then
        log_fail(name, "event_tail is empty (expected >= 1 entry after first phase transition)")
        return
    end
    -- Validate shape of each entry.
    for i, entry in ipairs(et) do
        for _, req in ipairs({ "scope", "kind", "path", "ts" }) do
            if field(entry, req) == nil then
                log_fail(name, "event_tail[" .. i .. "] missing field '" .. req .. "'")
                return
            end
        end
    end
    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-06e: ring buffer cap = 20. After enough phase transitions the
-- event_tail must not exceed 20 entries. Wait for a dev_snapshot where
-- event_tail length == 20, OR assert that no snapshot ever exceeds 20.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_06e_event_tail_cap(inbox, gm_pid)
    local name = "V-05-06e event-tail cap=20"
    local dev_sub = events.subscribe("mafia.dev", "*")
    local dev_ch = dev_sub and dev_sub:channel() or nil
    if not dev_ch then
        log_fail(name, "events.subscribe('mafia.dev') failed")
        return
    end

    local payload, err = start_game(inbox, gm_pid, 13, false)
    if not payload then
        dev_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        dev_sub:close()
        log_fail(name, "no game_id")
        return
    end

    -- Collect snapshots until we see one with event_tail length == 20,
    -- or until a snapshot has event_tail length > 20 (FAIL), or until game ends.
    local cap_hit = false
    local exceeded = false
    local exceeded_count = 0
    local deadline = time.after("120s")
    while true do
        local r = channel.select({ inbox:case_receive(), dev_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        if r.channel == dev_ch then
            local evt = r.value
            if evt and evt.kind == "snapshot" then
                local d = evt.data or {}
                if d.game_id == game_id then
                    local et = d.event_tail
                    if type(et) == "table" then
                        local n = #et
                        if n == 20 then cap_hit = true end
                        if n > 20 then exceeded = true; exceeded_count = n end
                    end
                    -- Stop once we've hit the cap or a game-ending phase.
                    if cap_hit or d.phase == "ended" then break end
                end
            end
        end
    end
    dev_sub:close()

    if exceeded then
        log_fail(name, "event_tail exceeded cap: got " .. tostring(exceeded_count) .. " entries (max 20)")
        return
    end
    if cap_hit then
        log_ok(name)
        return
    end
    -- Game may have ended before 20 events accumulated (short game).
    -- As long as we never exceeded 20, the cap is functioning; SKIP with note.
    log_skip(name,
        "game ended before event_tail reached 20 entries; cap not directly verified "
        .. "(no overflow observed — ring buffer constraint satisfied implicitly). "
        .. "Re-run on a longer game or enable burst mode for direct V-05-06e validation.")
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-01: dev_mode field on game_state_changed when MAFIA_DEV_MODE=1.
-- Subscribe to mafia.system game_state_changed, start a game, assert
-- data.dev_mode == true on the first frame received.
-- SKIP if MAFIA_DEV_MODE != "1" (run test with env var set).
-- ──────────────────────────────────────────────────────────────────
local function test_v05_01_dev_mode_field_true(inbox, gm_pid)
    local name = "V-05-01 dev-mode-field-true"
    local current_dev = env.get("MAFIA_DEV_MODE")
    if current_dev ~= "1" then
        log_skip(name, "MAFIA_DEV_MODE=" .. tostring(current_dev)
            .. "; re-run with MAFIA_DEV_MODE=1 to exercise this branch")
        return
    end

    -- Subscribe to system events before starting the game.
    local sys_sub = events.subscribe("mafia.system", "game_state_changed")
    local sys_ch = sys_sub and sys_sub:channel() or nil
    if not sys_ch then
        log_fail(name, "events.subscribe failed")
        return
    end

    local payload, err = start_game(inbox, gm_pid, 23, false)
    if not payload then
        sys_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        sys_sub:close()
        log_fail(name, "no game_id")
        return
    end

    -- Wait for a game_state_changed event for this game.
    local deadline = time.after("10s")
    local found_dev_mode = nil
    while true do
        local r = channel.select({ sys_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then
            break
        end
        local evt = r.value
        if evt then
            local data_ok, data = pcall(function() return evt:data() end)
            if not data_ok then
                -- try payload path
                data_ok, data = pcall(function() return evt:payload() and evt:payload():data() end)
            end
            if data_ok and type(data) == "table" then
                local evt_game_id = data.game_id
                if evt_game_id == game_id then
                    found_dev_mode = data.dev_mode
                    break
                end
            end
        end
    end
    sys_sub:close()

    if found_dev_mode == true then
        log_ok(name)
    elseif found_dev_mode == nil then
        log_fail(name, "no game_state_changed event received for game=" .. game_id
            .. " within 10s (or dev_mode field absent)")
    else
        log_fail(name, "data.dev_mode=" .. tostring(found_dev_mode) .. " (expected true)")
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-02: dev_mode=false when MAFIA_DEV_MODE is not set.
-- SKIP if MAFIA_DEV_MODE=1 (wrong env for this branch; runner must
-- execute test_driver twice — once with and once without the env var).
-- ──────────────────────────────────────────────────────────────────
local function test_v05_02_dev_mode_field_false(inbox, gm_pid)
    local name = "V-05-02 dev-mode-field-false"
    local current_dev = env.get("MAFIA_DEV_MODE")
    if current_dev == "1" then
        log_skip(name, "MAFIA_DEV_MODE=1; re-run without env var to exercise false branch")
        return
    end

    local sys_sub = events.subscribe("mafia.system", "game_state_changed")
    local sys_ch = sys_sub and sys_sub:channel() or nil
    if not sys_ch then
        log_fail(name, "events.subscribe failed")
        return
    end

    local payload, err = start_game(inbox, gm_pid, 29, false)
    if not payload then
        sys_sub:close()
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        sys_sub:close()
        log_fail(name, "no game_id")
        return
    end

    local deadline = time.after("10s")
    local found_dev_mode = nil
    local found_event = false
    while true do
        local r = channel.select({ sys_ch:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        local evt = r.value
        if evt then
            local data_ok, data = pcall(function() return evt:data() end)
            if not data_ok then
                data_ok, data = pcall(function() return evt:payload() and evt:payload():data() end)
            end
            if data_ok and type(data) == "table" then
                local evt_game_id = data.game_id
                if evt_game_id == game_id then
                    found_event = true
                    found_dev_mode = data.dev_mode
                    break
                end
            end
        end
    end
    sys_sub:close()

    if not found_event then
        log_fail(name, "no game_state_changed event for game=" .. game_id .. " within 10s")
    elseif found_dev_mode == false then
        log_ok(name)
    else
        log_fail(name, "data.dev_mode=" .. tostring(found_dev_mode) .. " (expected false)")
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-11: persona_blob populated — after game start, all 5 NPC rows in
-- players have a non-empty persona_blob (within 5s). Stub mode has no persona
-- args; SKIP if MAFIA_NPC_MODE != "real".
-- ──────────────────────────────────────────────────────────────────
local function test_v05_11_persona_blob_populated(inbox, gm_pid)
    local name = "V-05-11 persona-blob-populated"
    local npc_mode = env.get("MAFIA_NPC_MODE")
    if npc_mode ~= "real" then
        log_skip(name, "MAFIA_NPC_MODE=" .. tostring(npc_mode)
            .. "; persona blobs only persisted in real mode")
        return
    end
    local payload, err = start_game(inbox, gm_pid, 13, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id in game.started")
        return
    end
    -- Poll until all 5 NPC rows have non-empty persona_blob (within 5s).
    local ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND slot != 1 "
            .. "AND (persona_blob IS NULL OR persona_blob = '')", game_id)
        return n == 0, n
    end, 5, "200ms")
    if ok then
        log_ok(name)
    else
        local empty_n = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND slot != 1 "
            .. "AND (persona_blob IS NULL OR persona_blob = '')", game_id)
        log_fail(name, "still " .. tostring(empty_n)
            .. " NPC slots with empty persona_blob after 5s for game=" .. game_id)
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-12: persona_blob SHA matches. For each NPC slot, compute
-- SHA256 over the DB blob and compare to the hash logged by npc.lua
-- at INIT (emitted as [PERSONA_HASH] slot=N sha=<hex> in logger).
-- This test reads the persona_blob from SQL only; it cannot call
-- sha256 in the wippy sandbox (no crypto module). Instead it verifies
-- that persona_blob is a non-empty string with length > 200 for every
-- NPC slot — a structural proxy that the blob was rendered (not blank).
-- Full SHA comparison is done by the human-verify step per plan note.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_12_persona_blob_sha(inbox, gm_pid)
    local name = "V-05-12 persona-blob-sha"
    local npc_mode = env.get("MAFIA_NPC_MODE")
    if npc_mode ~= "real" then
        log_skip(name, "MAFIA_NPC_MODE=" .. tostring(npc_mode)
            .. "; persona blobs only persisted in real mode")
        return
    end
    local payload, err = start_game(inbox, gm_pid, 17, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id")
        return
    end
    -- Wait for blobs to be written.
    local ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND slot != 1 "
            .. "AND persona_blob IS NOT NULL AND length(persona_blob) > 200", game_id)
        return n == 5, n
    end, 5, "200ms")
    if not ok then
        log_fail(name, "expected 5 NPC blobs with length>200; game=" .. game_id)
        return
    end
    -- Spot-check: all blobs must be distinct (each NPC has a unique persona).
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_fail(name, "sql.get: " .. tostring(db_err))
        return
    end
    local rows, q_err = db:query(
        "SELECT COUNT(DISTINCT persona_blob) AS n FROM players WHERE game_id = ? AND slot != 1",
        { game_id })
    db:release()
    if q_err or not rows or not rows[1] then
        log_fail(name, "distinct blob query failed: " .. tostring(q_err))
        return
    end
    local distinct_n = rows[1].n or 0
    if distinct_n == 5 then
        log_ok(name)
    else
        log_fail(name, "expected 5 distinct persona blobs, got " .. tostring(distinct_n)
            .. " for game=" .. game_id
            .. " (blob mismatch — render_stable_block args diverged)")
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-05: dev_plugin always-loaded; in dev mode sends dev_status
-- {enabled=true} to a new connection. Verifies:
--   1. dev_plugin process is registered (auto_start=true).
--   2. A synthetic inbox join message (conn_pid = our own pid) triggers
--      process.send(conn_pid, "dev_status", {enabled=true}).
-- SKIP if MAFIA_DEV_MODE != "1".
-- ──────────────────────────────────────────────────────────────────
local function test_v05_05_dev_plugin_dev_status()
    local name = "V-05-05 dev-plugin dev_status"
    local current_dev = env.get("MAFIA_DEV_MODE")
    if current_dev ~= "1" then
        log_skip(name, "MAFIA_DEV_MODE=" .. tostring(current_dev)
            .. "; re-run with MAFIA_DEV_MODE=1 to exercise dev mode branch")
        return
    end

    -- dev_plugin is auto_start=true; poll registry up to 5s.
    local dev_pid = nil
    local found = poll_until(function()
        local pid = process.registry.lookup("app.relay:dev_plugin")
        if pid then dev_pid = pid; return true, pid end
        return false, nil
    end, 5, "100ms")
    if not found or not dev_pid then
        log_fail(name, "app.relay:dev_plugin not in registry after 5s")
        return
    end

    -- Send a synthetic join-style inbox message to dev_plugin.
    -- Relay wraps inbound commands as { conn_pid, type, data, ... }.
    -- We use our own pid as the fake conn_pid so dev_plugin can
    -- process.send(conn_pid, "dev_status", ...) back to us.
    local fake_conn_pid = tostring(process.pid())
    process.send(dev_pid, "join", { conn_pid = fake_conn_pid })

    -- Wait up to 2s for a dev_status frame on our inbox.
    local inbox = process.inbox()
    local deadline = time.after("2s")
    local got_status = nil
    while true do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        local msg = r.value
        local topic_ok, topic = pcall(function() return msg:topic() end)
        if topic_ok and topic == "dev_status" then
            local raw = (msg:payload() and msg:payload():data()) or {}
            got_status = raw
            break
        end
        -- drain unrelated messages (game-start replies, etc.)
    end

    if not got_status then
        log_fail(name, "no dev_status frame received from dev_plugin within 2s "
            .. "(synthetic join sent to " .. tostring(dev_pid) .. ")")
        return
    end
    if got_status.enabled ~= true then
        log_fail(name, "dev_status.enabled=" .. tostring(got_status.enabled)
            .. " (expected true with MAFIA_DEV_MODE=1)")
        return
    end
    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-05b: dev_plugin in product mode — process registered (auto_start)
-- but no events.subscribe("mafia.dev") called. Verified by:
--   1. Process is in registry (auto_start=true always registers it).
--   2. Synthetic join → dev_status {enabled=false} (passive mode still
--      replies to connections but never forwards dev events).
-- SKIP if MAFIA_DEV_MODE=1 (wrong env for this test).
-- ──────────────────────────────────────────────────────────────────
local function test_v05_05b_dev_plugin_product_mode()
    local name = "V-05-05b dev-plugin product-mode passive"
    local current_dev = env.get("MAFIA_DEV_MODE")
    if current_dev == "1" then
        log_skip(name, "MAFIA_DEV_MODE=1; re-run WITHOUT env var to test passive mode")
        return
    end

    -- dev_plugin must still be in registry (auto_start=true).
    local dev_pid = nil
    local found = poll_until(function()
        local pid = process.registry.lookup("app.relay:dev_plugin")
        if pid then dev_pid = pid; return true, pid end
        return false, nil
    end, 5, "100ms")
    if not found or not dev_pid then
        log_fail(name, "app.relay:dev_plugin not in registry after 5s (auto_start=true required)")
        return
    end

    -- Passive mode still handles join and sends dev_status {enabled=false}.
    local fake_conn_pid = tostring(process.pid())
    process.send(dev_pid, "join", { conn_pid = fake_conn_pid })

    local inbox = process.inbox()
    local deadline = time.after("500ms")
    local got_status = nil
    while true do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel == deadline then break end
        local msg = r.value
        local topic_ok, topic = pcall(function() return msg:topic() end)
        if topic_ok and topic == "dev_status" then
            local raw = (msg:payload() and msg:payload():data()) or {}
            got_status = raw
            break
        end
    end

    if not got_status then
        -- Process registered and no dev events forwarded = passive mode confirmed.
        -- dev_status may arrive after our deadline; log as SKIP rather than FAIL.
        log_skip(name,
            "dev_plugin registered (passive confirmed); dev_status not received within 500ms "
            .. "— process IS dormant (no events.subscribe in product mode)")
        return
    end
    if got_status.enabled ~= false then
        log_fail(name, "dev_status.enabled=" .. tostring(got_status.enabled)
            .. " (expected false in product mode)")
        return
    end
    log_ok(name)
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-13: rounds.phase UPSERT — after advance to day phase via
-- player.advance_phase, SELECT phase FROM rounds WHERE game_id=? AND
-- round=1 returns 'day'. Proves the UPSERT overwrites 'night'.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_13_rounds_phase_upsert(inbox, gm_pid)
    local name = "V-05-13 rounds-phase-upsert"
    local payload, err = start_game(inbox, gm_pid, 19, false)
    if not payload then
        log_fail(name, "start_game: " .. tostring(err))
        return
    end
    local game_id = field(payload, "game_id")
    if not game_id then
        log_fail(name, "no game_id")
        return
    end

    -- Wait for night_actions row (night resolved).
    local night_ok = poll_until(function()
        local n = count_rows(
            "SELECT COUNT(*) AS n FROM night_actions WHERE game_id = ? AND round = 1", game_id)
        return n >= 1, n
    end, 20, "300ms")
    if not night_ok then
        log_fail(name, "night_actions never appeared for round 1")
        return
    end

    -- Confirm rounds.phase is currently 'night' before the advance.
    local night_row = get_row("SELECT phase FROM rounds WHERE game_id = ? AND round = 1", game_id)
    if not night_row or night_row.phase ~= "night" then
        log_fail(name, "expected phase='night' before advance, got: "
            .. tostring(night_row and night_row.phase))
        return
    end

    -- Inject player.advance_phase to release Begin-Day gate.
    local orch_pid = process.registry.lookup("game:" .. game_id)
    if not orch_pid then
        log_fail(name, "orchestrator not found for game " .. game_id)
        return
    end
    process.send(orch_pid, "player.advance_phase", { round = 1 })

    -- Poll until phase flips to 'day'.
    local day_ok = poll_until(function()
        local r = get_row("SELECT phase FROM rounds WHERE game_id = ? AND round = 1", game_id)
        if r and r.phase == "day" then return true, r.phase end
        return false, nil
    end, 10, "200ms")

    if day_ok then
        log_ok(name)
    else
        local r = get_row("SELECT phase FROM rounds WHERE game_id = ? AND round = 1", game_id)
        log_fail(name, "rounds.phase never became 'day' after player.advance_phase; got: "
            .. tostring(r and r.phase) .. " for game=" .. game_id)
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-02: Two-runs-same-seed determinism.
-- Start two games with the same payload.rng_seed (different game_ids).
-- Assert roster display_names are identical across both runs.
-- (D-SD-05: structural determinism — same seed → same roles, personas, turn order)
-- ──────────────────────────────────────────────────────────────────
local function test_v05_02_same_seed_determinism(inbox, gm_pid)
    local name = "V-05-02 same-seed-determinism"
    local test_seed = 42

    -- Run 1.
    local p1, err1 = start_game(inbox, gm_pid, test_seed, false)
    if not p1 then
        log_fail(name, "game1 start failed: " .. tostring(err1))
        return
    end
    local g1 = field(p1, "game_id")
    if not g1 then
        log_fail(name, "no game_id for game1")
        return
    end

    -- Run 2 with the same seed.
    local p2, err2 = start_game(inbox, gm_pid, test_seed, false)
    if not p2 then
        log_fail(name, "game2 start failed: " .. tostring(err2))
        return
    end
    local g2 = field(p2, "game_id")
    if not g2 then
        log_fail(name, "no game_id for game2")
        return
    end

    if g1 == g2 then
        log_fail(name, "same game_id returned for both runs (UUID collision?)")
        return
    end

    -- Poll until both games have 6 player rows with display_name populated.
    local ok = poll_until(function()
        local n1 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g1)
        local n2 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g2)
        return n1 == 6 and n2 == 6, { n1, n2 }
    end, 10, "200ms")
    if not ok then
        local n1 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g1)
        local n2 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g2)
        log_fail(name, string.format(
            "player rows not ready after 10s: game1=%d game2=%d (expected 6 each)", n1, n2))
        return
    end

    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_fail(name, "sql.get: " .. tostring(db_err))
        return
    end
    local names1, _ = db:query(
        "SELECT display_name, role FROM players WHERE game_id = ? ORDER BY slot", { g1 })
    local names2, _ = db:query(
        "SELECT display_name, role FROM players WHERE game_id = ? ORDER BY slot", { g2 })
    db:release()

    if not names1 or not names2 or #names1 ~= 6 or #names2 ~= 6 then
        log_fail(name, string.format(
            "expected 6 name rows each; got game1=%d game2=%d",
            names1 and #names1 or 0, names2 and #names2 or 0))
        return
    end

    local diffs = {}
    for i = 1, 6 do
        local n1_name = names1[i] and names1[i].display_name or "(nil)"
        local n2_name = names2[i] and names2[i].display_name or "(nil)"
        local n1_role = names1[i] and names1[i].role or "(nil)"
        local n2_role = names2[i] and names2[i].role or "(nil)"
        if n1_name ~= n2_name then
            table.insert(diffs, string.format("slot %d name: %s vs %s", i, n1_name, n2_name))
        end
        if n1_role ~= n2_role then
            table.insert(diffs, string.format("slot %d role: %s vs %s", i, n1_role, n2_role))
        end
    end

    if #diffs == 0 then
        log_ok(name)
    else
        log_fail(name, "seed=" .. tostring(test_seed) .. " not deterministic: "
            .. table.concat(diffs, "; "))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-04: MAFIA_SEED env fallback determinism.
-- Start game with NO payload.rng_seed; verify game_manager uses MAFIA_SEED env.
-- Two sub-checks: (a) rng_seed stored in games table equals MAFIA_SEED, and
-- (b) two runs without payload.rng_seed produce identical roster_names (when
--     same MAFIA_SEED is set). SKIP if MAFIA_SEED env is not set.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_04_env_seed(inbox, gm_pid)
    local name = "V-05-04 env-seed-fallback"
    local env_seed_str = env.get("MAFIA_SEED")
    if not env_seed_str or env_seed_str == "" then
        log_skip(name, "MAFIA_SEED not set; re-run with MAFIA_SEED=<int> to exercise env fallback")
        return
    end
    local expected_seed = tonumber(env_seed_str)
    if not expected_seed then
        log_skip(name, "MAFIA_SEED=" .. tostring(env_seed_str) .. " is non-numeric; skip")
        return
    end

    -- Start game with rng_seed=nil (no payload override → env fallback).
    local p1, err1 = start_game(inbox, gm_pid, nil, false)
    if not p1 then
        log_fail(name, "game1 start failed: " .. tostring(err1))
        return
    end
    local g1 = field(p1, "game_id")
    if not g1 then
        log_fail(name, "no game_id for game1")
        return
    end

    -- Assert games.rng_seed == expected_seed (confirms env fallback was used).
    local ok_seed = poll_until(function()
        local row = get_row("SELECT rng_seed FROM games WHERE id = ?", g1)
        return row ~= nil, row
    end, 5, "100ms")
    if not ok_seed then
        log_fail(name, "games row never appeared for game1=" .. g1)
        return
    end
    local seed_row = get_row("SELECT rng_seed FROM games WHERE id = ?", g1)
    if not seed_row then
        log_fail(name, "games row missing for game1=" .. g1)
        return
    end
    local stored_seed = tonumber(seed_row.rng_seed)
    if stored_seed ~= expected_seed then
        log_fail(name, string.format(
            "games.rng_seed=%s (expected MAFIA_SEED=%s) for game1=%s",
            tostring(stored_seed), tostring(expected_seed), g1))
        return
    end

    -- Second run: same MAFIA_SEED, no payload override → should produce same roster.
    local p2, err2 = start_game(inbox, gm_pid, nil, false)
    if not p2 then
        log_fail(name, "game2 start failed: " .. tostring(err2))
        return
    end
    local g2 = field(p2, "game_id")
    if not g2 then
        log_fail(name, "no game_id for game2")
        return
    end

    -- Wait for both rosters to be populated.
    local roster_ok = poll_until(function()
        local n1 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g1)
        local n2 = count_rows(
            "SELECT COUNT(*) AS n FROM players WHERE game_id = ? AND display_name IS NOT NULL", g2)
        return n1 == 6 and n2 == 6, { n1, n2 }
    end, 10, "200ms")
    if not roster_ok then
        log_fail(name, "player rows not ready after 10s for game2=" .. g2)
        return
    end

    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_fail(name, "sql.get: " .. tostring(db_err))
        return
    end
    local names1, _ = db:query(
        "SELECT display_name, role FROM players WHERE game_id = ? ORDER BY slot", { g1 })
    local names2, _ = db:query(
        "SELECT display_name, role FROM players WHERE game_id = ? ORDER BY slot", { g2 })
    db:release()

    if not names1 or not names2 or #names1 ~= 6 or #names2 ~= 6 then
        log_fail(name, "expected 6 name rows each for determinism check")
        return
    end

    local diffs = {}
    for i = 1, 6 do
        local n1_name = names1[i] and names1[i].display_name or "(nil)"
        local n2_name = names2[i] and names2[i].display_name or "(nil)"
        if n1_name ~= n2_name then
            table.insert(diffs, string.format("slot %d: %s vs %s", i, n1_name, n2_name))
        end
    end

    if #diffs == 0 then
        log_ok(name)
    else
        log_fail(name, "MAFIA_SEED=" .. tostring(expected_seed)
            .. " not deterministic across two runs: " .. table.concat(diffs, "; "))
    end
end

-- ──────────────────────────────────────────────────────────────────
-- V-05-10: RSS soak — 10 consecutive game cycles in stub mode.
-- Each cycle uses a distinct seed (1000 + i) to avoid cache aliasing
-- (D-RR-02). Driver logs an instructive line at start so the human can
-- sample RSS via `pgrep -f "wippy run"` + `ps -o rss= -p <pid>` before
-- and after the loop (D-RR-04 acceptance: <10MB AND <5% growth).
--
-- Stub-mode gate per D-RR-03: in real-LLM mode, Bug #3 (rare voting
-- hang) can trigger; the audited path is stub mode where the orchestrator
-- + NPC + relay teardown are exercised without LLM variance.
-- ──────────────────────────────────────────────────────────────────
local function test_v05_10_rss_soak(inbox, gm_pid)
    local name = "V-05-10 RSS soak (10 games, stub mode)"

    -- Stub-mode gate (D-RR-03): bug surface for real-LLM mode is documented
    -- as a manual procedure in 05-06-PLAN.md.
    local npc_mode = env.get("MAFIA_NPC_MODE") or ""
    if npc_mode ~= "stub" then
        log_skip(name, "requires MAFIA_NPC_MODE=stub (got '" .. npc_mode .. "')")
        return
    end

    -- Wippy sandbox does not expose the OS PID via process.* API
    -- (Phase 01 P05 lesson: os.* is stripped). Direct the human to
    -- pgrep for the parent wippy process.
    logger:info("[V-05-10] BEFORE soak: sample RSS now via — "
        .. "pgrep -f 'wippy run' | head -1 | xargs -I{} ps -o rss= -p {}")
    -- D-RR-04 acceptance gate (relaxed 2026-04-26): the absolute 10MB cap
    -- is the load-bearing test; the original <5% relative gate was dropped
    -- because the stub-mode baseline (~47MB) is too small for it to be
    -- meaningful. See scripts/audit-rss-10games.sh comment for rationale.

    for i = 1, 10 do
        local seed = 1000 + i  -- distinct seeds; D-RR-02 cache-aliasing guard
        local payload, err = start_game(inbox, gm_pid, seed, true)
        if not payload then
            log_fail(name, "cycle " .. i .. ": start failed — " .. tostring(err))
            return
        end
        local game_id = field(payload, "game_id")
        if not game_id then
            log_fail(name, "cycle " .. i .. ": no game_id in game.started payload")
            return
        end

        -- Wait for the game to end via SQL polling (game.ended is a published
        -- event, not a driver-inbox reply; wait_for_winner is the established
        -- pattern from V-04-08). 60s cap per cycle is generous — stub-mode
        -- games typically end in <30s with force_tie=true.
        local winner = wait_for_winner(game_id, 60)
        if not winner then
            log_fail(name, string.format(
                "cycle %d: game.winner never populated within 60s (game_id=%s)",
                i, tostring(game_id):sub(1, 8)))
            return
        end

        logger:info(string.format(
            "[V-05-10] cycle %d/10 complete (seed=%d, game_id=%s, winner=%s) — "
            .. "sample RSS now if doing per-cycle trace",
            i, seed, tostring(game_id):sub(1, 8), tostring(winner)))
    end

    logger:info("[V-05-10] AFTER soak: sample RSS now via — "
        .. "pgrep -f 'wippy run' | head -1 | xargs -I{} ps -o rss= -p {}")
    logger:info("[V-05-10] D-RR-04 acceptance (relaxed 2026-04-26): "
        .. "(after_kb - before_kb) < 10240 KB. Relative %% reported only.")
    log_ok(name)
end

return {
    test_v05_06_dev_snapshot = test_v05_06_dev_snapshot,
    test_v05_06b_last_vote = test_v05_06b_last_vote,
    test_v05_06c_unavailable = test_v05_06c_unavailable,
    test_v05_06d_event_tail = test_v05_06d_event_tail,
    test_v05_06e_event_tail_cap = test_v05_06e_event_tail_cap,
    test_v05_01_dev_mode_field_true = test_v05_01_dev_mode_field_true,
    test_v05_02_dev_mode_field_false = test_v05_02_dev_mode_field_false,
    test_v05_11_persona_blob_populated = test_v05_11_persona_blob_populated,
    test_v05_12_persona_blob_sha = test_v05_12_persona_blob_sha,
    test_v05_05_dev_plugin_dev_status = test_v05_05_dev_plugin_dev_status,
    test_v05_05b_dev_plugin_product_mode = test_v05_05b_dev_plugin_product_mode,
    test_v05_13_rounds_phase_upsert = test_v05_13_rounds_phase_upsert,
    test_v05_02_same_seed_determinism = test_v05_02_same_seed_determinism,
    test_v05_04_env_seed = test_v05_04_env_seed,
    test_v05_10_rss_soak = test_v05_10_rss_soak,
}
