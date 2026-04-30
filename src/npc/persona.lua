-- src/npc/persona.lua
-- D-13/D-15: Stable persona block builder.
-- Phase 1 back-compat: render_stable_block(fixture, role) two-arg form still works.
-- Phase 3 form:        render_stable_block(args) where args is the full parameterised table.
-- No clocks, no RNG, no env reads — pure string assembly.

local persona_pool  = require("persona_pool")
local persona_rules = require("persona_rules")

local FIXTURE = {
    name      = "Mira Kapoor",
    archetype = "the nervous analyst",
    voice     = "hedges, asks clarifying questions, flags inconsistencies",
    traits    = { "cautious", "detail-oriented", "second-guesses herself" },
}

-- Game rules block — pulled from persona_rules so the [[ ]] literal lives
-- in its own tiny module and can't cascade into this file's highlighting.
-- Byte-identical to the Phase 1 shipped RULES string (D-15 SHA-256 anchor).
local RULES = persona_rules.RULES

-- Phase 1 render path — kept byte-identical to the original.
local function render_phase1(fixture, role)
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

-- Phase 3 render path — parameterised args table.
-- ORDER FIXED: changing positions below triggers SHA256 drift (D-15).
-- args = {archetype, name, voice_quirk, canonical_utterances,
--         role, partner_name?, roster_names[], rules_text?}
local function render_phase3(args)
    local rules = args.rules_text or RULES
    local parts = {}
    table.insert(parts, rules)
    table.insert(parts, "\n\n===ROLE===\n" .. args.role)
    if args.role == "mafia" and args.partner_name then
        table.insert(parts, "Your Mafia partner: " .. args.partner_name)
    end
    table.insert(parts, "\n\n===YOU===")
    table.insert(parts, "Name: " .. args.name)
    table.insert(parts, "Archetype: " .. args.archetype)
    table.insert(parts, "Voice: " .. args.voice_quirk)
    table.insert(parts, "\nExample utterances in your voice:")
    for _, u in ipairs(args.canonical_utterances) do
        table.insert(parts, "- \"" .. u .. "\"")
    end
    table.insert(parts, "\n\n===ROSTER===")
    for _, n in ipairs(args.roster_names or {}) do
        table.insert(parts, "- " .. n)
    end
    table.insert(parts, "\n\n===STRATEGY===")
    table.insert(parts, args.role == "mafia"
        and "You're Mafia. Blend in. Don't out yourself. Deflect accusation. Steer votes away from your partner."
        or  "You're Villager. Observe. Pressure. Vote informed. Watch for deflection.")
    table.insert(parts, "\n\n===INFO DISCIPLINE===")
    table.insert(parts, "You know only what's been said in public chat or happened publicly (eliminations, votes).")
    table.insert(parts, args.role == "mafia"
        and "You also know who your partner is; do NOT name them as mafia in public chat."
        or  "You do NOT know anyone's role. Never claim night knowledge. Never claim anyone's role as fact.")
    return table.concat(parts, "\n")
end

--- render_stable_block — polymorphic.
--- Phase 3: render_stable_block(args_table)  where args.archetype is a string.
--- Phase 1: render_stable_block(fixture, role) two-arg back-compat.
local function render_stable_block(args, role)
    if type(role) == "string" then
        -- Phase 1 back-compat: called as (fixture, role)
        return render_phase1(args, role)
    end
    return render_phase3(args)
end

--- derive_persona_args — helper for the orchestrator (Plan 03).
--- Looks up archetype by id in persona_pool.ARCHETYPES and assembles the full args table.
local function derive_persona_args(archetype_id, name, role, partner_name, roster_names)
    local archetype = nil
    for _, a in ipairs(persona_pool.ARCHETYPES) do
        if a.id == archetype_id then
            archetype = a
            break
        end
    end
    assert(archetype, "unknown archetype_id: " .. tostring(archetype_id))
    return {
        name                 = name,
        archetype            = archetype.archetype,
        voice_quirk          = archetype.voice,
        canonical_utterances = archetype.canonical_utterances,
        role                 = role,
        partner_name         = partner_name,
        roster_names         = roster_names or {},
        rules_text           = RULES,
    }
end

return {
    FIXTURE              = FIXTURE,
    RULES                = RULES,
    render_stable_block  = render_stable_block,
    derive_persona_args  = derive_persona_args,
}
