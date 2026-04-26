-- src/lib/det_rng.lua
-- Deterministic linear congruential PRNG for Mafia structural setup.
--
-- Why this exists: Wippy's Lua runtime does NOT honour math.randomseed —
-- two orchestrator processes seeded with the same integer produce different
-- math.random outputs (verified empirically against the [orchestrator] roles
-- shuffled / personas sampled traces). That breaks D-SD-05's structural
-- determinism contract: same seed must produce same role layout + same
-- persona-to-slot assignment.
--
-- Design: a small Numerical-Recipes LCG (a=1664525, c=1013904223, m=2^32),
-- self-contained in pure Lua, no math.random calls anywhere. State lives in
-- the returned table — fully isolated from any other RNG consumers.
--
-- Numbers fit safely in Lua doubles: max state * a + c ≈ 7.15e15 < 2^53 (9e15).
--
-- Use only for STRUCTURAL determinism (role shuffle, persona pick). LLM
-- chat/votes/picks remain stochastic and continue to use whatever the
-- framework provides (D-SD-05).

local M = {}

local A = 1664525
local C = 1013904223
local MOD = 4294967296  -- 2^32

local function step(state)
    return (state * A + C) % MOD
end

-- new(seed) — returns an RNG. `seed` is coerced to a non-negative integer
-- via floor + mod 2^32. Negative or fractional seeds are accepted.
function M.new(seed)
    seed = math.floor(tonumber(seed) or 0) % MOD
    if seed < 0 then seed = seed + MOD end
    -- Warmup: LCG low bits are weak in the first few iterations. A handful of
    -- steps before the caller observes any output gives the bit distribution
    -- room to mix without changing the math-determinism guarantee.
    local state = seed
    for _ = 1, 4 do state = step(state) end
    local rng = { _state = state }
    return setmetatable(rng, { __index = M })
end

-- int(n) — returns an integer in [1, n]. n must be >= 1.
function M.int(self, n)
    self._state = step(self._state)
    return (self._state % n) + 1
end

return M
