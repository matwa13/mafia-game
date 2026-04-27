-- src/game/chat.lua
-- D-02 / D-15: This file is the SOLE writer of `chat.line` events. The path
-- itself encodes the invariant — `scripts/audit-grep.sh` D-15 gate (line ~49)
-- references this file by name. Any other source file calling
-- `pe.publish_event(_, "chat.line", ...)` is a regression.
-- D-20: Also the SOLE INSERT site for the `messages` table.
-- Pitfall 5 (RESEARCH §): chat_seq is the caller's per-round counter table;
-- function signature is unchanged; mutation lands in caller's state by Lua
-- table-by-reference semantics. Do NOT introduce a local chat_seq inside this file.

local logger = require("logger"):named("chat")
local time   = require("time")
local sql    = require("sql")
local pe     = require("pe")

-- Write one message row and publish chat.line. SOLE site that mutates chat_seq
-- and SOLE publisher of `chat.line`. SETUP-05: INSERT precedes publish_event.
-- Returns the assigned seq on success, or nil + err on failure.
-- Optional `kind` param (default "npc") allows "human" and "last_words" callers.
-- Optional `preassigned_seq`: if provided, use it instead of auto-incrementing.
-- This lets an NPC turn RESERVE its seq at start (before streaming) so that any
-- user interjection committed during the turn gets a seq numerically HIGHER
-- than the NPC's — guaranteeing the NPC's bubble renders above the user's
-- when the SPA sorts by seq.
local function commit_chat_line(game_id, round, from_slot, text, chat_seq, kind, preassigned_seq, scope)
    kind = kind or "npc"
    local effective_scope = type(scope) == "string" and scope or "public"
    local seq
    if preassigned_seq then
        seq = preassigned_seq
    else
        chat_seq[round] = (chat_seq[round] or 0) + 1
        seq = chat_seq[round]
    end

    local db, db_err = sql.get("app:db")
    if db_err or not db then
        return nil, "sql.get: " .. tostring(db_err)
    end
    local _, exec_err = db:execute(
        "INSERT INTO messages (game_id, round, seq, phase, from_slot, kind, text, created_at) VALUES (?, ?, ?, 'day', ?, ?, ?, ?)",
        { game_id, round, seq, from_slot, kind, text, time.now():unix() }
    )
    db:release()
    if exec_err then
        return nil, "messages.insert: " .. tostring(exec_err)
    end

    -- SETUP-05: publish AFTER successful INSERT.
    pe.publish_event(effective_scope, "chat.line", "/" .. game_id, {
        round = round,
        seq = seq,
        from_slot = from_slot,
        text = text,
        kind = kind,
    })
    return seq, nil
end

-- commit_player_chat: convenience wrapper for human interjections (kind="human").
-- D-15 invariant: routes through commit_chat_line, the SOLE writer of messages.
local function commit_player_chat(game_id, round, from_slot, text, chat_seq)
    return commit_chat_line(game_id, round, from_slot, tostring(text or ""), chat_seq, "human")
end

return {
    commit_chat_line = commit_chat_line,
    commit_player_chat = commit_player_chat,
}
