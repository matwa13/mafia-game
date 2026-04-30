-- Phase 3 vote metadata: per-NPC JSON-blob suspicion snapshots.
-- Additive only. Existing normalized (slot, about_slot, value) rows from
-- 0001 remain queryable; Phase 3 writers now insert per-NPC JSON blobs
-- with npc_id + snapshot_json populated, leaving about_slot/value as
-- placeholder values (0 / 0.0) since SQLite ALTER cannot relax NOT NULL.
return require("migration").define(function()
  migration("Phase 3: per-NPC suspicion snapshot JSON blob", function()
    database("sqlite", function()
      up(function(db)
        db:execute("ALTER TABLE suspicion_snapshots ADD COLUMN npc_id TEXT")
        db:execute("ALTER TABLE suspicion_snapshots ADD COLUMN snapshot_json TEXT")
        return true
      end)
      down(function(db)
        -- SQLite has no DROP COLUMN pre-3.35. Down is a no-op; rollback via full reset.
        return true
      end)
    end)
  end)
end)
