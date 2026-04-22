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

    local function subscribe_to_game(game_id)
        chat_sub = events.subscribe("mafia.public", "*")
        sys_sub = events.subscribe("mafia.system", "*")
        chat_ch = chat_sub and chat_sub:channel() or nil
        sys_ch = sys_sub and sys_sub:channel() or nil
        logger:info("[game_plugin] subscribed", { user_id = user_id, game_id = game_id })
    end

    local function unsubscribe()
        if chat_sub then chat_sub:close(); chat_sub = nil; chat_ch = nil end
        if sys_sub then sys_sub:close(); sys_sub = nil; sys_ch = nil end
    end

    logger:info("[game_plugin] started", { user_id = user_id })

    while true do
        local cases = { inbox:case_receive(), proc_ev:case_receive() }
        if chat_ch then table.insert(cases, chat_ch:case_receive()) end
        if sys_ch then table.insert(cases, sys_ch:case_receive()) end
        local r = channel.select(cases)
        if not r.ok then break end

        if r.channel == inbox then
            -- Task 2 fills in dispatch for topics: start, chat_send, vote_cast.
            local msg = r.value
            local topic = msg and msg:topic() or ""
            local payload = (msg and msg:payload() and msg:payload():data()) or {}
            local conn_pid = payload.conn_pid
            local data = payload.data or {}

            if type(conn_pid) == "string" and not conns[conn_pid] then
                conns[conn_pid] = { joined_at = time.now():unix() }
            end

            -- TODO Task 2: dispatch start / chat_send / vote_cast.
            -- TODO Task 2: also handle "game.started" reply from game_manager.

            logger:debug("[game_plugin] inbox (scaffold)",
                { topic = tostring(topic), conn_pid = tostring(conn_pid) })

        elseif (chat_ch and r.channel == chat_ch) or (sys_ch and r.channel == sys_ch) then
            -- TODO Task 3: forward events to conn_pid based on evt.kind mapping.
            logger:debug("[game_plugin] event (scaffold)", {
                kind = r.value and r.value.kind, path = r.value and r.value.path,
            })

        elseif r.channel == proc_ev then
            local ev = r.value
            if ev and ev.kind == process.event.CANCEL then
                unsubscribe()
                logger:info("[game_plugin] CANCEL; exiting")
                return
            end
        end
    end

    unsubscribe()
end

return { run = run }
