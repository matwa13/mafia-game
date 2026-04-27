-- src/npc/prompts.lua
-- D-04 (Phase 6): Sole home for build_chat_prompt + build_vote_prompt + assert_stable_hash.
-- Pattern H non-negotiable: the persona block (state.stable_block) is byte-identical across
-- all turns — this file does NOT modify the block, only wraps it with prompt:add_system +
-- prompt:add_cache_marker in the exact order established in Phase 1 (D-15/D-13 SHA256 anchor).
-- cache_control = ephemeral marker: prompt:add_cache_marker() is called once per prompt,
-- immediately after add_system(stable_block) — see 06-RESEARCH §G for the ephemeral-marker
-- contract (changing the call order breaks the cache hit).
-- Function bodies are verbatim-moved from src/npc/npc.lua — NO reordering, NO wrapping.

local prompt          = require("prompt")
local hash            = require("hash")
local persona         = require("persona")
local visible_context = require("visible_context")

--- assert_stable_hash(state) — re-compute SHA-256 over the persona block and
--- assert equal to the boot-time hash. Panic on mismatch (D-15 Phase 1 inherited).
local function assert_stable_hash(state)
    local now_bytes = tostring(persona.render_stable_block(state.persona_args))
    local now_hash = hash.sha256(now_bytes)
    assert(now_hash == state.stable_hash,
        string.format("PERSONA DRIFT: npc=%s boot_hash=%s now_hash=%s",
            state.npc_id, state.stable_hash, now_hash))
end

local function build_chat_prompt(state, is_mandatory)
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
        roster_names = state.roster_names,
        slot = state.slot,
    }, "chat")
    -- D-DP-06: capture last dynamic tail for dev telemetry.
    state.last_dynamic_tail = tail
    -- Phase 3.1: both turns are mandatory. The 2nd turn is a short reactive
    -- follow-up, not an optional skip. This eliminates the DECLINE token
    -- entirely — the LLM has no reason to emit it because it's not in the
    -- prompt anymore.
    local directive
    if is_mandatory then
        directive = "\n\n===SPEAK NOW — OPENING===\nIt's your turn to open. In 1-2 short sentences (max ~40 words), share your read on the day so far. Address other players by name when you accuse, defend, or question. Do NOT write paragraphs."
    else
        directive = "\n\n===SPEAK NOW — FOLLOW-UP===\nAdd ONE short follow-up sentence (max ~25 words) that reacts to what was just said. Sharpen an accusation, defend yourself, or call out someone's silence. Always say something concrete — no filler."
    end
    p:add_user(tail .. directive)
    return p
end

local function build_vote_prompt(state)
    local p = prompt.new()
    p:add_system(state.stable_block)
    p:add_cache_marker()
    local vote_mode = "vote"
    local tail = visible_context(state.npc_id, {
        role = state.role,
        event_log = state.event_log or {},
        roster = state.roster or {},
        suspicion = state.suspicion,
        roster_names = state.roster_names,
        slot = state.slot,
    }, vote_mode)
    -- D-DP-06: capture last dynamic tail for dev telemetry.
    state.last_dynamic_tail = tail
    local directive = [[


===VOTE NOW===
Update your private suspicion of each named player in this round, then cast your vote.
Rules:
- suspicion_updates are DELTAS in [-20, +20] keyed by player NAME. Add for Mafia-aligned behavior, subtract for Villager-aligned behavior.
- reflection_notes are short (<=60 chars) per-player reads this round, keyed by NAME.
- vote_target MUST be the NAME of a living non-self player. Abstention is not allowed — you are required to vote even with imperfect information. Pick whoever feels most suspicious right now.
- reasoning must quote or clearly reference something a specific player said today; address them by name.
- Do NOT vote for yourself. Do NOT bandwagon without a specific reason.]]
    p:add_user(tail .. directive)
    return p
end

return {
    assert_stable_hash = assert_stable_hash,
    build_chat_prompt  = build_chat_prompt,
    build_vote_prompt  = build_vote_prompt,
}
