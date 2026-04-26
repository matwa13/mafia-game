-- src/lib/events.lua
-- D-09: publish_event is the ONLY approved `events.send` path. Grep-auditable
-- via `grep -rn 'events.send' src/` — must return exactly one match (this file).
-- D-11: scope_allowed is a pure predicate; the panic assert belongs at the
-- call site in visible_context, not here (this returns a boolean only).

local events = require("events")

local ALLOWED_SCOPES = { public = true, mafia = true, system = true }

local function publish_event(scope, kind, path, data)
    assert(ALLOWED_SCOPES[scope], "publish_event: bad scope " .. tostring(scope))
    data = data or {}
    data.scope = scope
    return events.send("mafia." .. scope, kind, path, data)
end

local ROLE_SCOPES = {
    villager = { public = true, system = true },
    mafia    = { public = true, system = true, mafia = true },
}

local function scope_allowed(role, scope)
    local allowed = ROLE_SCOPES[role]
    if not allowed then return false end
    return allowed[scope] == true
end

-- D-DP-05: publish_dev_event uses "mafia.dev" system name — NOT in ALLOWED_SCOPES.
-- NPCs subscribe only to mafia.public / mafia.mafia / mafia.system; they never
-- see mafia.dev events. Belt-and-suspenders firewall (Research Pitfall 4).
-- D-09: this is the ONLY `events.send` path; the "mafia.dev" send is inside this
-- module so the grep gate `grep -rn 'events.send' src/ | grep -v src/lib/events.lua`
-- stays clean.
local function publish_dev_event(kind, path, data)
    data = data or {}
    data.scope = "dev"
    return events.send("mafia.dev", kind, path, data)
end

return {
    publish_event = publish_event,
    publish_dev_event = publish_dev_event,
    scope_allowed = scope_allowed,
}
