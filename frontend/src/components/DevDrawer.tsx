import { useState } from "react";
import { useStore } from "../store";
import { DevNpcCard } from "./DevNpcCard";
import { DevEventTail } from "./DevEventTail";

export function DevDrawer() {
  const dev = useStore((s) => s.dev);
  const game = useStore((s) => s.game);
  const [open, setOpen] = useState(true);

  // Build a name lookup from dev roster for suspicion target labels.
  const rosterNames: Record<number, string> = {};
  for (const [slotStr, npc] of Object.entries(dev.roster)) {
    if (npc?.name) rosterNames[Number(slotStr)] = npc.name;
  }
  // Also include game roster names as fallback.
  for (const [slotStr, entry] of Object.entries(game.roster)) {
    if (!rosterNames[Number(slotStr)] && entry?.name) {
      rosterNames[Number(slotStr)] = entry.name;
    }
  }

  if (!open) {
    return (
      <aside
        role="complementary"
        aria-label="Dev panel"
        style={{
          width: 40,
          flexShrink: 0,
          borderLeft: "1px solid var(--color-border)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          transition: "width 200ms ease-out",
        }}
      >
        <button
          onClick={() => setOpen(true)}
          aria-label="Expand dev panel"
          aria-expanded={false}
          style={{
            color: "var(--color-text-muted)",
            background: "none",
            border: "none",
            cursor: "pointer",
            fontSize: 16,
            padding: "8px 4px",
            minHeight: 44,
          }}
        >
          ›
        </button>
      </aside>
    );
  }

  const mafiaNames = dev.mafiaPartnerSlots
    ? dev.mafiaPartnerSlots.map((s) => ({
        slot: s,
        name: dev.roster[s]?.name ?? rosterNames[s] ?? `slot ${s}`,
      }))
    : null;

  return (
    <aside
      role="complementary"
      aria-label="Dev panel"
      style={{
        width: 360,
        flexShrink: 0,
        borderLeft: "1px solid var(--color-border)",
        display: "flex",
        flexDirection: "column",
        overflowY: "auto",
        transition: "width 200ms ease-out",
      }}
    >
      {/* Header strip */}
      <div
        className="flex items-center px-3 text-xs"
        style={{
          height: 40,
          flexShrink: 0,
          background: "var(--color-surface)",
          borderBottom: "1px solid var(--color-border)",
          color: "var(--color-text-muted)",
          position: "sticky",
          top: 0,
          zIndex: 1,
        }}
      >
        <span className="truncate">
          {game.seed != null ? `seed=${game.seed}` : "seed=—"}
          {" · "}
          {game.gameId ? `game_id=${game.gameId.slice(0, 8)}` : "game_id=—"}
          {" · "}
          Round {game.round}
          {" · "}
          Phase {game.phase ?? "—"}
        </span>
        <button
          onClick={() => setOpen(false)}
          aria-label="Collapse dev panel"
          aria-expanded={true}
          style={{
            marginLeft: "auto",
            color: "var(--color-text-muted)",
            background: "none",
            border: "none",
            cursor: "pointer",
            fontSize: 16,
            padding: "4px 8px",
            minHeight: 44,
            flexShrink: 0,
          }}
        >
          ‹
        </button>
      </div>

      {/* Mafia pairing row */}
      {mafiaNames && (
        <div
          className="px-3 py-2 text-xs"
          style={{
            borderBottom: "1px solid var(--color-border)",
            color: "var(--color-role-mafia)",
          }}
        >
          Mafia:{" "}
          {mafiaNames.map((m, i) => (
            <span key={m.slot}>
              {i > 0 && " + "}
              {m.name} (slot {m.slot})
            </span>
          ))}
        </div>
      )}

      {/* NPC cards */}
      <div className="flex flex-col gap-2 px-3 py-2" style={{ flex: 1 }}>
        {[1, 2, 3, 4, 5].map((slot) => (
          <DevNpcCard
            key={slot}
            slot={slot}
            npc={dev.roster[slot]}
            mafiaSlots={dev.mafiaPartnerSlots}
            rosterNames={rosterNames}
          />
        ))}
      </div>

      {/* Event tail */}
      <DevEventTail events={dev.eventTail} />
    </aside>
  );
}
