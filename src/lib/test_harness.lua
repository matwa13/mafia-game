-- src/lib/test_harness.lua
-- T-03: Shared helpers for src/game/test_driver.lua and src/npc/test_driver.lua.
-- Log format strings (`[TEST] %s OK|FAIL|SKIP`) match Phase 1 D-21.
-- Wait/poll helpers use channel.select on a deadline, matching the existing
-- src/probes/probe.lua and test_driver patterns.
-- Phase 6 cut 3: bodies moved verbatim from src/game/test_driver.lua:18-127
-- (logger:named substitution from "test_driver" → "test_harness" is the only
-- behavior change permitted; per 06-PATTERNS.md S-4).

local time    = require("time")
local channel = require("channel")
local sql     = require("sql")

-- ──────────────────────────────────────────────────────────────────
-- Log helpers (exact Phase 1 format strings per D-21).
--
-- Logger is resolved per-call (not captured at module load): a logger
-- handle captured at library load time silently no-ops when invoked
-- from an importing process. Inline `require("logger"):named(...)`
-- inside each call resolves to a working handle for the active process.
-- ──────────────────────────────────────────────────────────────────
local function log_ok(name)
    require("logger"):named("test_harness"):info(string.format("[TEST] %s OK", name))
end
local function log_fail(name, reason)
    require("logger"):named("test_harness"):error(string.format("[TEST] %s FAIL: %s", name, tostring(reason)))
end
local function log_skip(name, reason)
    require("logger"):named("test_harness"):info(string.format("[TEST] %s SKIP: %s", name, tostring(reason)))
end

-- Pull a table field via pairs(); the language-server narrows r.value inside
-- channel.select branches and warns on direct dot-access.
local function field(t, key)
    if type(t) ~= "table" then return nil end
    for k, v in pairs(t) do if k == key then return v end end
    return nil
end

-- ──────────────────────────────────────────────────────────────────
-- Registry lookup with bounded retry. game_manager auto-starts at
-- lifecycle level 1; driver's first lookup can race its registry.register.
-- ──────────────────────────────────────────────────────────────────
local function lookup_game_manager(max_attempts, delay)
    max_attempts = max_attempts or 50
    delay = delay or "100ms"
    for _ = 1, max_attempts do
        local pid = process.registry.lookup("app.game:game_manager")
        if pid then return pid end
        time.sleep(delay)
    end
    return nil, "gm not found"
end

-- Wait for an inbox reply with the given topic (or any topic if nil).
local function wait_for_reply(inbox, cap, expected_topic)
    local deadline = time.after(cap)
    while true do
        local r = channel.select({ inbox:case_receive(), deadline:case_receive() })
        if not r.ok or r.channel ~= inbox then return nil, "timeout " .. cap end
        local topic_ok, topic = pcall(function() return r.value:topic() end)
        if not topic_ok then return nil, "bad message: " .. tostring(topic) end
        if not expected_topic or topic == expected_topic then return r.value, nil end
    end
end

-- ──────────────────────────────────────────────────────────────────
-- SQL helpers. Acquire-per-call + release (Phase 1 Plan 05 idiom).
-- Params passed as a single array table per D-30 (Phase 1 Plan 05).
-- ──────────────────────────────────────────────────────────────────
-- count_rows(sql_str, ...) — variadic params (same rationale as get_row).
local function count_rows(sql_str, ...)
    local db, err = sql.get("app:db")
    if err or not db then return -1, "sql.get: " .. tostring(err) end
    local rows, q_err = db:query(tostring(sql_str), { ... })
    db:release()
    if q_err or not rows or not rows[1] then return -1, tostring(q_err) end
    local r = rows[1]
    local n = r.n or r.count or r["COUNT(*)"] or 0
    return n, nil
end

-- get_row(sql_str, ...) — variadic params avoid wippy lint's positional-tuple
-- unification across call sites (some pass 1 param, some 2 — a non-variadic
-- params table would be narrowed to the shortest tuple).
local function get_row(sql_str, ...)
    local db, err = sql.get("app:db")
    if err or not db then return nil, "sql.get: " .. tostring(err) end
    local rows, q_err = db:query(tostring(sql_str), { ... })
    db:release()
    if q_err then return nil, tostring(q_err) end
    return rows and rows[1] or nil, nil
end

-- Poll a predicate up to cap seconds. predicate() returns (ok, value).
local function poll_until(predicate, cap_s, step)
    local deadline = time.now():unix() + (cap_s or 10)
    local effective_step = type(step) == "string" and step or "200ms"
    while time.now():unix() < deadline do
        local ok, val = predicate()
        if ok then return true, val end
        time.sleep(effective_step)
    end
    return false, nil
end

-- ──────────────────────────────────────────────────────────────────
-- Shared scenario helpers.
-- ──────────────────────────────────────────────────────────────────

-- Send game.start; wait for game.started reply. Returns the decoded payload
-- table on success or nil + err on failure / error payload.
local function start_game(inbox, gm_pid, rng_seed, force_tie)
    process.send(gm_pid, "game.start", {
        rng_seed = rng_seed,
        player_slot = 1,
        force_tie = force_tie == true,
        driver_pid = process.pid(),
    })
    local msg, err = wait_for_reply(inbox, "10s", "game.started")
    if not msg then return nil, err end
    local raw = msg:payload():data()
    if type(raw) ~= "table" then return nil, "game.started payload not table" end
    if raw.error then return nil, "game.started error: " .. tostring(raw.error) end
    return raw, nil
end

-- Poll games.winner until non-null or timeout.
local function wait_for_winner(game_id, cap_s)
    local effective_cap = type(cap_s) == "number" and cap_s or 30
    local deadline = time.now():unix() + effective_cap
    while time.now():unix() < deadline do
        local row = get_row("SELECT winner, ended_at FROM games WHERE id = ?", game_id)
        if row and row.winner then return row.winner, row.ended_at end
        time.sleep("500ms")
    end
    return nil, nil
end

return {
    log_ok = log_ok,
    log_fail = log_fail,
    log_skip = log_skip,
    field = field,
    lookup_game_manager = lookup_game_manager,
    wait_for_reply = wait_for_reply,
    count_rows = count_rows,
    get_row = get_row,
    poll_until = poll_until,
    start_game = start_game,
    wait_for_winner = wait_for_winner,
}
