-- Phase 0 boot-time probe service. Delivers D-06's "done" signal:
--     every [PROBE] line prints OK, no browser action required.
-- Per D-07, runs unconditionally on every `wippy run`.
--
-- Each probe logs exactly one line:
--     [PROBE] <name> OK
--   OR [PROBE] <name> FAIL: <reason>
-- Binary outcome only — a probe that cannot complete MUST emit FAIL.
--
-- The four probes:
--   1. db              — sqlite_master lists the 8 Mafia tables (SC2 smoke)
--   2. events-ordering — publish N events on core/events, read back in order (SC4a)
--   3. registry-xprocess — resolve app.probes:probe_target by name, ping/pong (SC4b)
--   4. echo            — outbound Lua WebSocket client round-trip via /ws (SC3)

local logger = require("logger"):named("probe")
local events = require("events")
local time = require("time")
local json = require("json")
local sql = require("sql")
local websocket = require("websocket")

local function log_ok(name)
    logger:info(string.format("[PROBE] %s OK", name))
end
local function log_fail(name, reason)
    logger:error(string.format("[PROBE] %s FAIL: %s", name, tostring(reason)))
end

-- ──────────────────────────────────────────────────────────────────
-- Probe 1: [PROBE] db — confirm all 8 tables exist in sqlite_master.
-- Emits exactly one [PROBE] db OK on success or [PROBE] db FAIL on error.
-- ──────────────────────────────────────────────────────────────────
local function probe_db(db)
    if not db then
        return log_fail("db", "no db handle available")
    end
    local expected = {
        "games", "players", "rounds", "messages", "votes",
        "night_actions", "suspicion_snapshots", "eliminations",
    }
    -- Migrations run via the bootloader concurrently with probe_service
    -- startup at lifecycle level 1. On clean-slate boot (no prior DB file)
    -- the query can land before the schema has been populated. Retry for
    -- ~5 seconds until all 8 expected tables appear — mirrors the registry
    -- retry in probe_registry_xprocess (Rule 3, blocking race fix).
    local last_missing, last_err
    for attempt = 1, 50 do
        local rows, err = db:query(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        if err or not rows then
            last_err = err
        else
            local found = {}
            for _, row in ipairs(rows) do found[row.name] = true end
            local missing = nil
            for _, t in ipairs(expected) do
                if not found[t] then
                    missing = t
                    break
                end
            end
            if not missing then
                return log_ok("db")
            end
            last_missing = missing
        end
        time.sleep("100ms")
    end
    if last_err then
        return log_fail("db", "query failed: " .. tostring(last_err))
    end
    return log_fail("db", "missing table after 5s: " .. tostring(last_missing))
end

-- ──────────────────────────────────────────────────────────────────
-- Probe 2: [PROBE] events-ordering — publish N events on core/events,
-- read back in order. Uses events.subscribe(system, kind) + events.send()
-- per the live lua/core/events API (NOT the topic:publish/subscribe
-- shape the plan's interface block suggested).
-- Emits one [PROBE] events-ordering OK or [PROBE] events-ordering FAIL.
-- ──────────────────────────────────────────────────────────────────
local function probe_events_ordering()
    local N = 20
    local suffix = tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
    local system = "app.probes"
    local kind = "ordering-" .. suffix

    local sub, sub_err = events.subscribe(system, kind)
    if sub_err or not sub then
        return log_fail("events-ordering", "subscribe: " .. tostring(sub_err))
    end
    local ch = sub:channel()

    for i = 1, N do
        local ok, send_err = events.send(system, kind, "/probe/" .. suffix, { seq = i })
        if not ok or send_err then
            return log_fail("events-ordering",
                string.format("send seq=%d: %s", i, tostring(send_err)))
        end
    end

    for i = 1, N do
        local r = channel.select({
            ch:case_receive(),
            time.after("1s"):case_receive(),
        })
        if not r.ok or r.channel ~= ch then
            return log_fail("events-ordering", "timeout at seq=" .. tostring(i))
        end
        local evt = r.value
        local got = evt and evt.data and evt.data.seq
        if got ~= i then
            return log_fail("events-ordering",
                string.format("out-of-order: expected %d got %s", i, tostring(got)))
        end
    end
    log_ok("events-ordering")
end

-- ──────────────────────────────────────────────────────────────────
-- Probe 3: [PROBE] registry-xprocess — lookup sibling by name, ping,
-- await pong. Emits one [PROBE] registry-xprocess OK or FAIL.
-- ──────────────────────────────────────────────────────────────────
local function probe_registry_xprocess()
    -- Brief retry loop: probe_service and probe_target_service both live at
    -- lifecycle level 1 and start concurrently; probe_target's own
    -- registry.register call may race with our lookup on boot. Retry ~1s.
    local target_pid, lookup_err
    for attempt = 1, 10 do
        target_pid, lookup_err = process.registry.lookup("app.probes:probe_target")
        if target_pid then break end
        time.sleep("100ms")
    end
    if lookup_err or not target_pid then
        return log_fail("registry-xprocess", "lookup: " .. tostring(lookup_err))
    end

    local ok, send_err = process.send(target_pid, "ping", { from = process.pid() })
    if not ok or send_err then
        return log_fail("registry-xprocess", "send ping: " .. tostring(send_err))
    end

    local inbox = process.inbox()
    local r = channel.select({
        inbox:case_receive(),
        time.after("2s"):case_receive(),
    })
    if not r.ok or r.channel ~= inbox then
        return log_fail("registry-xprocess", "no pong within 2s")
    end

    local topic = r.value:topic()
    if topic ~= "pong" then
        return log_fail("registry-xprocess", "unexpected topic: " .. tostring(topic))
    end
    log_ok("registry-xprocess")
end

-- ──────────────────────────────────────────────────────────────────
-- Probe 4: echo — INLINE outbound WebSocket round-trip.
--   Opens ws://127.0.0.1:8080/ws/ (trailing slash — Wippy's router
--   307-redirects /ws → /ws/ and WS clients do not follow redirects),
--   sends {type:"echo_ping", ...}, awaits {topic:"echo_pong", ...},
--   emits [PROBE] echo OK on success, [PROBE] echo FAIL: <reason> otherwise.
-- ──────────────────────────────────────────────────────────────────
local function probe_echo()
    local url = "ws://127.0.0.1:8080/ws/"
    local client, err = websocket.connect(url, {
        dial_timeout = "3s",
        read_timeout = "3s",
        write_timeout = "3s",
        headers = {
            -- Relay's wsrelay.allowed.origins is "http://localhost:8080";
            -- set Origin explicitly so the upgrade passes same-origin check.
            ["Origin"] = "http://localhost:8080",
        },
    })
    if err or not client then
        return log_fail("echo", "connect: " .. tostring(err))
    end

    local ping = json.encode({
        type = "echo_ping",
        data = { ts = os.time(), src = "probe" },
    })
    client:send(ping)

    local ch = client:channel()
    -- First frame is the relay's "welcome" envelope — skip it and wait
    -- for the real echo_pong frame. Give up after 3s total.
    local deadline = time.after("3s")
    local frame = nil
    while true do
        local r = channel.select({
            ch:case_receive(),
            deadline:case_receive(),
        })
        if not r.ok or r.channel ~= ch then
            client:close(websocket.CLOSE_CODES.NORMAL, "probe timeout")
            return log_fail("echo", "no echo_pong within 3s")
        end

        local msg = r.value
        if not msg or not msg.data then
            client:close(websocket.CLOSE_CODES.NORMAL, "probe no data")
            return log_fail("echo", "empty ws frame")
        end

        local ok_json, decoded = pcall(json.decode, msg.data)
        if not ok_json then
            client:close(websocket.CLOSE_CODES.NORMAL, "probe bad json")
            return log_fail("echo", "json decode error: " .. tostring(decoded))
        end
        if type(decoded) ~= "table" then
            client:close(websocket.CLOSE_CODES.NORMAL, "probe not a table")
            return log_fail("echo", "frame not a json object: type=" .. type(decoded))
        end

        -- The websocket_relay middleware wraps outbound plugin frames as
        -- {topic: "echo_pong", data: {...}}; the relay's welcome frame
        -- uses a different topic (e.g. "wippy.relay.hub.welcome").
        if decoded.topic == "echo_pong" then
            frame = decoded
            break
        end
        -- otherwise keep reading (welcome / heartbeat frames)
    end

    client:close(websocket.CLOSE_CODES.NORMAL, "probe done")
    if not frame then
        return log_fail("echo", "no echo_pong received")
    end
    log_ok("echo")
end

-- ──────────────────────────────────────────────────────────────────
-- Main entry
-- ──────────────────────────────────────────────────────────────────
local function run(_args)
    logger:info("[probe] starting Phase 0 probes")

    -- Acquire DB handle from sql resource registry (not imports — the
    -- registry dependency resolver doesn't create a node edge for an
    -- `app:db` service referenced in imports on a process.lua entry;
    -- use sql.get at runtime instead).
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        log_fail("db", "sql.get: " .. tostring(db_err))
    else
        probe_db(db)
    end

    probe_events_ordering()
    probe_registry_xprocess()
    probe_echo()

    if db then
        db:release()
    end

    logger:info("[probe] all checks complete")

    -- Stay alive until CANCEL so registry state is stable for follow-up.
    local evs = process.events()
    while true do
        local r = channel.select({ evs:case_receive() })
        if r.ok and r.value and r.value.kind == process.event.CANCEL then
            return
        end
        if not r.ok then
            return
        end
    end
end

return { run = run }
