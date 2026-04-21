-- Errors table migration (D-07 — LLM call failure persistence).
-- Columns locked by research Open Question #1 resolution.
-- Never edit after landing — schema changes go in 0003_*, etc.

return require("migration").define(function()
  migration("Create errors table", function()
    database("sqlite", function()
      up(function(db)
        db:execute([[
          CREATE TABLE IF NOT EXISTS errors (
            ts INTEGER NOT NULL,
            npc_id TEXT NOT NULL,
            call_type TEXT NOT NULL,
            http_code TEXT,
            message TEXT,
            retry_count INTEGER NOT NULL
          )
        ]])
        return true
      end)
      down(function(db)
        db:execute("DROP TABLE IF EXISTS errors")
        return true
      end)
    end)
  end)
end)
