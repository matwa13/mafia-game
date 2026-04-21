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

return {
    publish_event = publish_event,
    scope_allowed = scope_allowed,
}
