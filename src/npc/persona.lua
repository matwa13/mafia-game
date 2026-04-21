-- src/npc/persona.lua
-- D-13/D-15: Single-persona fixture + PURE render_stable_block(fixture, role).
-- Called exactly once at NPC boot; returned string is the byte-identity source
-- for the SHA-256 tripwire. No clocks, no RNG, no env reads.

local FIXTURE = {
    name      = "Mira Kapoor",
    archetype = "the nervous analyst",
    voice     = "hedges, asks clarifying questions, flags inconsistencies",
    traits    = { "cautious", "detail-oriented", "second-guesses herself" },
}

-- Short plain-English rules block. Inlined (not read from a file) so that
-- render_stable_block stays pure.
local RULES = [[
You are playing Mafia, a social deduction game.
Roles: 1 human + 5 NPC players; 2 are Mafia, 4 are Villagers.
Mafia know each other; Villagers do not know anyone else's role.
Each round: a night phase (Mafia eliminate one player) then a day phase
(discussion followed by a vote to lynch one suspected player).
Villagers win when all Mafia are eliminated; Mafia win when living Mafia
are equal to or outnumber living Villagers.
You speak in character as the persona described below. Stay in voice;
do not describe the game mechanically.
]]

local function render_stable_block(fixture, role)
    -- Byte-identical string assembly. Concatenation order and whitespace
    -- matter — the SHA-256 in Plan 04 is computed over this exact bytes.
    local parts = {
        RULES,
        "\nPersona:",
        "\n  name: " .. fixture.name,
        "\n  archetype: " .. fixture.archetype,
        "\n  voice: " .. fixture.voice,
        "\n  traits: " .. table.concat(fixture.traits, ", "),
        "\nYour role: " .. role,
    }
    return table.concat(parts, "")
end

return {
    FIXTURE = FIXTURE,
    render_stable_block = render_stable_block,
}
