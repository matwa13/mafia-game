-- Initial Mafia schema migration (8 tables).
-- Authoritative column shapes from .planning/research/ARCHITECTURE.md §7.
-- Never edit after landing — schema changes go in 0002_*, 0003_*, etc.

return require("migration").define(function()
  migration("Create initial Mafia schema", function()
    database("sqlite", function()
      up(function(db)
        db:execute([[
          CREATE TABLE IF NOT EXISTS games (
            id TEXT PRIMARY KEY,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            winner TEXT,
            player_slot INTEGER,
            player_role TEXT,
            rng_seed INTEGER
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS players (
            game_id TEXT NOT NULL,
            slot INTEGER NOT NULL,
            display_name TEXT NOT NULL,
            persona_blob TEXT,
            role TEXT NOT NULL,
            alive INTEGER NOT NULL DEFAULT 1,
            died_round INTEGER,
            died_cause TEXT,
            PRIMARY KEY (game_id, slot)
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS rounds (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            phase TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            PRIMARY KEY (game_id, round)
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS messages (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            phase TEXT NOT NULL,
            from_slot INTEGER,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (game_id, round, seq)
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS votes (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            from_slot INTEGER NOT NULL,
            vote_for_slot INTEGER,
            reasoning TEXT,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (game_id, round, from_slot)
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS night_actions (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            actor_slot INTEGER NOT NULL,
            target_slot INTEGER,
            created_at INTEGER NOT NULL
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS suspicion_snapshots (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            slot INTEGER NOT NULL,
            about_slot INTEGER NOT NULL,
            value REAL NOT NULL,
            created_at INTEGER NOT NULL
          )
        ]])
        db:execute([[
          CREATE TABLE IF NOT EXISTS eliminations (
            game_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            victim_slot INTEGER NOT NULL,
            cause TEXT NOT NULL,
            revealed_role TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (game_id, round, victim_slot)
          )
        ]])
        return true
      end)
      down(function(db)
        db:execute("DROP TABLE IF EXISTS eliminations")
        db:execute("DROP TABLE IF EXISTS suspicion_snapshots")
        db:execute("DROP TABLE IF EXISTS night_actions")
        db:execute("DROP TABLE IF EXISTS votes")
        db:execute("DROP TABLE IF EXISTS messages")
        db:execute("DROP TABLE IF EXISTS rounds")
        db:execute("DROP TABLE IF EXISTS players")
        db:execute("DROP TABLE IF EXISTS games")
        return true
      end)
    end)
  end)
end)
