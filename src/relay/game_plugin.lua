-- src/relay/game_plugin.lua
-- Phase 3 game relay plugin — AP2-compliant transport adapter.
--
-- Discovered by wippy/relay user hub; spawned per user. Holds ONLY
-- connection bookkeeping + active-game pointer — NO roster, NO phase,
-- NO chat history, NO votes, NO scope state.
--
-- Client frame contract:
--   inbound (browser -> plugin, AFTER prefix strip):
--     start       {seed?, force_tie?}
--     chat_send   {text, round?}
--     vote_cast   {vote_for_slot, round}
--   outbound (plugin -> browser, wrapped by websocket_relay as {topic, data}):
--     game_state_changed, game_chat_chunk, game_chat_line, game_chat_locked,
--     game_eliminated, game_vote_tied, game_votes_revealed, game_game_ended,
--     game_error.
--
-- Orchestrator contract:
--   plugin -> orchestrator: process.send(orch_pid, "player.chat"|"vote.cast", payload)
--   plugin <- orchestrator: subscribes to mafia.public:*, mafia.system:*;
--                           filters by evt.path == "/"..active.game_id.

local logger = require("logger"):named("game_plugin")
local events = require("events")
local channel = require("channel")
local time = require("time")
local env = require("env")

local MAX_CHAT_CHARS = 500  -- input validation clamp (Security T-03-01 V5)

local function forward(conn_pid, client_topic, data)
    -- websocket_relay middleware wraps this as {topic: client_topic, data: data}
    -- for the WS text frame.
    process.send(conn_pid, client_topic, data)
end

local function run(args)
    local user_id = args and args.user_id or "local-player"
    local inbox = process.inbox()
    local proc_ev = process.events()

    -- AP2: connection bookkeeping ONLY.
    local conns = {}                -- conn_pid -> { joined_at = ts }
    local active = nil              -- { game_id, orch_pid, player_slot } | nil
    local chat_sub, sys_sub = nil, nil
    local chat_ch, sys_ch = nil, nil
    local mafia_chat_sub, mafia_chat_ch = nil, nil

    -- Subscribe eagerly, before we know the game_id. Path filter is "*" so
    -- game_id is irrelevant to the subscription itself; the outer event loop
    -- rejects cross-game events via `evt.path == "/"..active.game_id`.
    --
    -- This MUST happen before `process.send(gm_pid, "game.start", ...)`:
    -- the orchestrator publishes its first `game_state_changed` (phase="intro")
    -- immediately after readiness, in the same tick as `orchestrator.ready`
    -- to game_manager. If we subscribe only after receiving `game.started`,
    -- the intro frame races and is lost — browser gets stuck on the plugin's
    -- synthetic "starting" frame.
    local function ensure_subscribed()
        if chat_sub and sys_sub then return end
        chat_sub = events.subscribe("mafia.public", "*")
        sys_sub = events.subscribe("mafia.system", "*")
        chat_ch = chat_sub and chat_sub:channel() or nil
        sys_ch = sys_sub and sys_sub:channel() or nil
        logger:info("[game_plugin] subscribed", { user_id = user_id })
    end

    local function unsubscribe()
        if chat_sub then chat_sub:close(); chat_sub = nil; chat_ch = nil end
        if sys_sub then sys_sub:close(); sys_sub = nil; sys_ch = nil end
    end

    local function ensure_mafia_subscribed()
        if mafia_chat_sub then return end
        mafia_chat_sub = events.subscribe("mafia.mafia", "*")
        mafia_chat_ch = mafia_chat_sub and mafia_chat_sub:channel() or nil
        logger:info("[game_plugin] mafia_chat subscribed", { user_id = user_id })
    end

    local function unsubscribe_mafia()
        if mafia_chat_sub then mafia_chat_sub:close(); mafia_chat_sub = nil; mafia_chat_ch = nil end
    end

    -- Phase 5 D-RH-01 / RESEARCH.md Pitfall 5: when the orchestrator is
    -- respawned mid-game (rehydration), active.orch_pid points at the dead
    -- pid and process.send silently drops. Re-look-up via process.registry
    -- before each player.* dispatch; the orchestrator re-registers under
    -- the same "game:<game_id>" key on respawn.
    local function refresh_orch_pid()
        if not (active and active.game_id) then return end
        local fresh = process.registry.lookup("game:" .. active.game_id)
        if fresh and fresh ~= active.orch_pid then
            logger:info("[game_plugin] orchestrator pid refreshed after rehydration",
                { game_id = active.game_id,
                  old_pid = tostring(active.orch_pid),
                  new_pid = tostring(fresh) })
            active.orch_pid = fresh
        end
    end

    logger:info("[game_plugin] started", { user_id = user_id })

    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if chat_ch then table.insert(cases, chat_ch:case_receive()) end
        if sys_ch then table.insert(cases, sys_ch:case_receive()) end
        if mafia_chat_ch then table.insert(cases, mafia_chat_ch:case_receive()) end
        local r = channel.select(cases)
        if not r.ok then break end

        if r.channel == inbox then
            local msg = r.value
            local topic = msg and msg:topic() or ""
            local payload = (msg and msg:payload() and msg:payload():data()) or {}
            local conn_pid = tostring(payload.conn_pid or "")
            local data = payload.data or {}

            if conn_pid ~= "" and not conns[conn_pid] then
                conns[conn_pid] = { joined_at = time.now():unix() }
                -- Phase 5 D-SD-03: bootstrap dev-mode flag to SPA before any
                -- game starts so SetupScreen can show the Seed input immediately.
                -- Plan 03's dev_plugin will eventually own this; for now
                -- game_plugin sends a synthetic frame on first join.
                forward(conn_pid, "dev_mode_changed", {
                    enabled = env.get("MAFIA_DEV_MODE") == "1",
                })
            end

            if topic == "start" then
                -- Look up game_manager, send game.start, wait inline <=5s for game.started reply.
                local gm_pid = process.registry.lookup("app.game:game_manager")
                if not gm_pid then
                    forward(conn_pid, "game_error", { code = "NO_GAME_MANAGER" })
                else
                    -- Sanitize + clamp the player name (V5 input validation).
                    -- Empty / missing → default "Player" so the game can still
                    -- start; the SPA is supposed to require non-empty at the
                    -- Setup screen, this is just defense-in-depth.
                    local pname = tostring(data.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if #pname > 32 then pname = pname:sub(1, 32) end
                    if pname == "" then pname = "Player" end

                    -- Subscribe BEFORE sending game.start to close the race
                    -- with the orchestrator's first game_state_changed emit.
                    ensure_subscribed()

                    process.send(gm_pid, "game.start", {
                        driver_pid = process.pid(),
                        -- D-SD-02: rename seed→rng_seed so game_manager's
                        -- three-step precedence (SPA > MAFIA_SEED env > random)
                        -- can read payload.rng_seed. tonumber handles nil safely.
                        rng_seed = tonumber(data.seed),
                        player_slot = 1,      -- MVP: human is always slot 1 (Phase 0 hardcode)
                        force_tie = data.force_tie == true,
                        player_name = pname,
                    })
                    -- Inline wait for the game.started reply (Phase 2 response contract).
                    local wait_deadline = time.after("5s")
                    local got_reply = false
                    while not got_reply do
                        local wait_r = channel.select({
                            inbox:case_receive(),
                            wait_deadline:case_receive(),
                        })
                        if not wait_r.ok or wait_r.channel == wait_deadline then
                            forward(conn_pid, "game_error", { code = "GAME_START_TIMEOUT" })
                            break
                        end
                        local reply_msg = wait_r.value
                        local reply_topic = reply_msg and reply_msg:topic() or ""
                        if reply_topic == "game.started" then
                            local started = (reply_msg:payload() and reply_msg:payload():data()) or {}
                            local orch_pid = process.registry.lookup("game:" .. tostring(started.game_id))
                            if not orch_pid then
                                forward(conn_pid, "game_error", { code = "ORCH_NOT_FOUND" })
                                got_reply = true
                                break
                            end
                            active = {
                                game_id = started.game_id,
                                orch_pid = orch_pid,
                                player_slot = started.player_slot or 1,
                            }
                            -- Phase 4 (LOOP-03): Mafia-human games get a third subscription on mafia.mafia
                            -- to receive side-chat events. Villager-human games skip this — no extra subscription,
                            -- no extra channel.select case, no overhead. Strict scope-isolation at the events layer.
                            if started.player_role == "mafia" then
                                ensure_mafia_subscribed()
                            end
                            -- Subscription already active (ensure_subscribed above);
                            -- setting `active` lets the event loop's path filter
                            -- start accepting events for this game_id.
                            forward(conn_pid, "game_state_changed", {
                                phase = "starting",
                                game_id = started.game_id,
                                player_slot = active.player_slot,
                            })
                            got_reply = true
                        elseif reply_topic == "game.start.failed" then
                            local ferr = (reply_msg:payload() and reply_msg:payload():data()) or {}
                            forward(conn_pid, "game_error", {
                                code = "GAME_START_FAILED", error = tostring(ferr.error or "unknown"),
                            })
                            got_reply = true
                        end
                        -- Any other topic during the wait window is dropped (no active game yet).
                    end
                end

            elseif topic == "chat_send" and active then
                -- Override from_slot with server-known player_slot (Spoofing T-03-01).
                -- Clamp text length (Input Validation V5).
                refresh_orch_pid()
                local text = tostring(data.text or "")
                if #text > MAX_CHAT_CHARS then text = text:sub(1, MAX_CHAT_CHARS) end
                if text ~= "" then
                    process.send(active.orch_pid, "player.chat", {
                        text = text,
                        from_slot = active.player_slot,
                        round = data.round,
                        conn_pid = conn_pid,
                    })
                end

            elseif topic == "vote_cast" and active then
                -- Override from_slot with server-known player_slot (Spoofing).
                -- Clamp vote_for_slot to a sane range (V5).
                refresh_orch_pid()
                local vfs = tonumber(data.vote_for_slot)
                if vfs and (vfs < 1 or vfs > 6) then vfs = nil end
                process.send(active.orch_pid, "vote.cast", {
                    from_slot = active.player_slot,
                    vote_for_slot = vfs,
                    reasoning = "player",
                    round = tonumber(data.round) or 0,
                })

            elseif topic == "advance_phase" and active then
                -- User clicked "End discussion →". Forward the signal to the
                -- orchestrator's run_day_discussion_streaming loop which will
                -- abort the in-flight NPC turn and exit to the vote phase.
                -- No from_slot override / no clamp needed — payload carries
                -- no user-supplied data beyond the intent signal.
                refresh_orch_pid()
                process.send(active.orch_pid, "player.advance_phase", {
                    round = tonumber(data.round) or 0,
                })

            elseif topic == "night_pick" and active then
                -- LOOP-02 (Mafia-human branch): human Mafia locks the kill target.
                -- Override from_slot with server-known player_slot (Spoofing T-04-01).
                -- Clamp target_slot to 1..6 (V5 input validation, mirrors vote_cast clamping).
                refresh_orch_pid()
                local target = tonumber(data.target_slot)
                if target and target >= 1 and target <= 6 then
                    process.send(active.orch_pid, "player.night_pick", {
                        from_slot = active.player_slot,
                        target_slot = target,
                        round = tonumber(data.round) or 0,
                    })
                end

            elseif topic == "mafia_chat_send" and active then
                -- LOOP-03: human Mafia sends a side-chat line. Mirrors chat_send: server overrides
                -- from_slot, clamps text to MAX_CHAT_CHARS (500). Orchestrator decides scope='mafia'
                -- when committing — plugin holds no scope state.
                refresh_orch_pid()
                local text = tostring(data.text or "")
                if #text > MAX_CHAT_CHARS then text = text:sub(1, MAX_CHAT_CHARS) end
                if text ~= "" then
                    process.send(active.orch_pid, "player.mafia_chat", {
                        text = text,
                        from_slot = active.player_slot,
                        round = tonumber(data.round) or 0,
                    })
                end

            elseif topic == "begin_day" and active then
                -- D-NU-02: human clicks "Begin Day →" after night-kill reveal. Reuses the
                -- existing player.advance_phase orchestrator handler (Plan 04 makes the
                -- night-side gate listen for the same topic). Dead-player guard does NOT
                -- apply: dead human can still advance the phase (CLAUDE.md flow invariant).
                refresh_orch_pid()
                process.send(active.orch_pid, "player.advance_phase", {
                    round = tonumber(data.round) or 0,
                })

            elseif topic == "start_game" and active then
                -- User clicked "Start game" on the intro screen. Unblocks the
                -- orchestrator's intro gate; the FSM enters Night 1.
                refresh_orch_pid()
                process.send(active.orch_pid, "player.start_game", {})

            elseif not active then
                logger:debug("[game_plugin] command with no active game; ignoring",
                    { topic = tostring(topic) })
            else
                logger:debug("[game_plugin] unknown post-strip topic",
                    { topic = tostring(topic) })
            end

        elseif (chat_ch and r.channel == chat_ch)
            or (sys_ch and r.channel == sys_ch)
            or (mafia_chat_ch and r.channel == mafia_chat_ch) then
            local evt = r.value
            if not evt or not active then
                -- drop — no active game or nil event
            elseif evt.path ~= "/" .. active.game_id then
                -- different game — drop
            else
                -- kind -> client_topic mapping
                local kind = tostring(evt.kind or "")
                local client_topic_map = {
                    ["chat.line"]             = "game_chat_line",
                    ["chat_locked"]           = "game_chat_locked",
                    ["player.eliminated"]     = "game_eliminated",
                    ["night.resolved"]        = "game_eliminated",  -- same client shape (Phase 4 ready)
                    ["vote.tied"]             = "game_vote_tied",
                    ["vote.cast.received"]    = "game_vote_cast_received",  -- incremental per-vote reveal
                    ["votes_revealed"]        = "game_votes_revealed",
                    ["day.discussion_ready"]  = "game_discussion_ready",    -- user-gated end of day
                    ["day.vote_complete"]     = "game_vote_complete",       -- user-gated start of next day
                    ["night.ready_for_day"]   = "game_night_ready_for_day", -- D-NU-02: Begin-Day gate signal
                    ["game.ended"]            = "game_game_ended",
                    ["game_state_changed"]    = "game_state_changed",
                    ["npc_turn_skipped"]      = "game_npc_skipped",  -- diagnostic for UI toast
                    ["typing.started"]        = "game_typing_started",
                    ["typing.ended"]          = "game_typing_ended",
                }
                local ct = client_topic_map[kind]
                if ct then
                    for cpid, _ in pairs(conns) do
                        forward(cpid, ct, evt.data or {})
                    end
                end
                -- Pitfall 9: on game.ended, drop subscriptions + clear active so next game starts fresh.
                if kind == "game.ended" then
                    unsubscribe()
                    unsubscribe_mafia()  -- Phase 4 (SETUP-04): drop mafia_chat sub before next game spawns.
                    active = nil
                    logger:info("[game_plugin] game ended; cleared active state")
                end
            end

        elseif r.channel == proc_ev then
            local ev = r.value
            if ev and ev.kind == process.event.CANCEL then
                unsubscribe()
                unsubscribe_mafia()
                logger:info("[game_plugin] CANCEL; exiting")
                return
            end
        end
    end

    unsubscribe()
    unsubscribe_mafia()
end

return { run = run }
