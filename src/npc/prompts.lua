-- src/npc/prompts.lua
-- D-04 (Phase 6): Sole home for build_chat_prompt + build_vote_prompt + assert_stable_hash.
-- Pattern H non-negotiable: the persona block (state.stable_block) is byte-identical across
-- all turns. Phase 7 D-05: persona block is now compiled into the agent definition's
-- `prompt` field (set in src/npc/npc.lua at ctx:load_agent time). The conversation passed
-- to runner:step contains ONLY the dynamic user message — no add_system, no add_cache_marker.
-- assert_stable_hash continues to anchor on the persona.render_stable_block output
-- (state.persona_args) byte-for-byte (Phase 1 D-15 tripwire preserved verbatim).

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
    -- Phase 7: user-message-only conversation. The agent runner injects the
    -- system prompt automatically from the agent definition (state.runner's
    -- compiled prompt field, set at ctx:load_agent time in src/npc/npc.lua).
    local p = prompt.new()
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
    --
    -- Phase 7 brevity tightening: pre-Phase-7 the `llm.generate` direct call
    -- reliably produced 1-2 sentence outputs. Under the agent runner the LLM
    -- treats the inline directive less strictly, so the cap is restated as
    -- a HARD LIMIT and given a "STOP at" rule to lean on Claude's
    -- instruction-following without changing max_tokens (which would also
    -- truncate the structured tool_calls used by vote/night_pick/side_chat).
    local directive
    if is_mandatory then
        directive = "\n\n===SPEAK NOW — OPENING===\nHARD LIMIT: 2 sentences max, 40 words max. STOP at the second period even mid-thought. Do NOT explain your reasoning. Do NOT apologize or hedge. Do NOT add disclaimers. Share your read on the day so far. Address other players by name when you accuse, defend, or question."
    else
        directive = "\n\n===SPEAK NOW — FOLLOW-UP===\nHARD LIMIT: 1 sentence, 25 words max. STOP at the period. React to what was just said — sharpen an accusation, defend yourself, or call out someone's silence. Say one concrete thing. Do NOT explain or hedge."
    end
    p:add_user(tail .. directive)
    return p
end

local function build_vote_prompt(state)
    -- Phase 7: user-message-only conversation. Agent runner injects system prompt.
    local p = prompt.new()
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
