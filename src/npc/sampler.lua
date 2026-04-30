-- src/npc/sampler.lua
-- Without-replacement Fisher-Yates persona sampler.
-- Pattern from src/game/orchestrator.lua shuffle_roles.
-- D-SD-05 (amended): math.randomseed is empirically a no-op across Wippy
-- orchestrator processes (same seed → different output). Use det_rng so
-- same-seed runs produce the same persona-to-slot assignment.
local det_rng = require("det_rng")

-- Returns a shuffled index list [1..n] using the given integer seed.
local function shuffled_indices(n, seed)
    local rng = det_rng.new(seed)
    local idx = {}
    for i = 1, n do idx[i] = i end
    for i = n, 2, -1 do
        local j = det_rng.int(rng, i)
        idx[i], idx[j] = idx[j], idx[i]
    end
    return idx
end

--- sample_personas(archetypes_pool, names_pool, count, rng_seed)
--- Returns `count` distinct persona records, deterministic on rng_seed.
--- Archetype shuffle uses rng_seed+1; name shuffle uses rng_seed+2,
--- decorrelating from orchestrator role shuffle (uses rng_seed directly).
local function sample_personas(archetypes_pool, names_pool, count, rng_seed)
    assert(#archetypes_pool >= count, "archetype pool smaller than count")
    assert(#names_pool >= count, "name pool smaller than count")
    local arch_seed = math.floor(rng_seed) + 1
    local name_seed = math.floor(rng_seed) + 2
    local arch_idx = shuffled_indices(#archetypes_pool, arch_seed)
    local name_idx = shuffled_indices(#names_pool, name_seed)
    local out = {}
    for i = 1, count do
        local a = archetypes_pool[arch_idx[i]]
        local name = names_pool[name_idx[i]]
        out[i] = {
            name                 = name,
            archetype_id         = a.id,
            archetype_label      = a.label,
            archetype            = a.archetype,
            voice_quirk          = a.voice,
            traits               = a.traits,
            canonical_utterances = a.canonical_utterances,
        }
    end
    return out
end

return { sample_personas = sample_personas }
