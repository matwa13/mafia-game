-- src/npc/persona_rules.lua
-- Isolated Mafia rules block — kept in its own tiny module so the [[ ]]
-- long-bracket literal (which the WebStorm Wippy plugin's tokeniser
-- mis-handles) can't cascade and break highlighting in persona.lua.
-- Byte-identical to the Phase 1 shipped RULES string (D-15 SHA-256 anchor).

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

return { RULES = RULES }
