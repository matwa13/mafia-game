-- Phase 4 night phase: add reasoning_json column to night_actions.
-- Additive only. Existing rows remain intact; new writes in Plan 04 will
-- populate reasoning_json when the NPC or orchestrator records the pick.
return require("migration").define(function()
  migration("Phase 4: night_actions reasoning + rounds writes", function()
    database("sqlite", function()
      up(function(db)
        local _, err = db:execute("ALTER TABLE night_actions ADD COLUMN reasoning_json TEXT")
        if err then return false, err end
        return true
      end)
      down(function(db)
        -- SQLite has no DROP COLUMN pre-3.35. Down is a no-op; rollback via full reset.
        return true
      end)
    end)
  end)
end)
