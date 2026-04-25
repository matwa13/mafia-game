import { useStore } from "../store";
import { Badge } from "./primitives/Badge";
import { RosterChip } from "./RosterChip";

function phaseLabel(
  phase: string | null,
  round: number,
  chatLocked: boolean,
  playerRole: string | null,
): string {
  if (!phase) return "";
  if (phase === "night") {
    return playerRole === "mafia" ? `NIGHT ${round} · MAFIA` : `NIGHT ${round}`;
  }
  if (phase === "day" && !chatLocked) return `DAY ${round} · DISCUSSION OPEN`;
  if (phase === "day" && chatLocked) return `DAY ${round} · LOCKED`;
  if (phase === "vote") return `DAY ${round} · VOTING`;
  if (phase === "reveal") return `DAY ${round} · RESOLVED`;
  if (phase === "ended") return `DAY ${round} · RESOLVED`;
  return `DAY ${round}`;
}

export function StatusBanner() {
  const game = useStore((s) => s.game);
  const { phase, round, roster, playerSlot, playerRole, partnerName, chatLocked } = game;

  const isDiscussionOpen = phase === "day" && !chatLocked;

  const living = Object.entries(roster)
    .filter(([, r]) => r.alive)
    .map(([slot]) => Number(slot));
  const dead = Object.entries(roster)
    .filter(([, r]) => !r.alive)
    .map(([slot]) => Number(slot));

  const label = phaseLabel(phase, round, chatLocked, playerRole);
  const roleVariant = playerRole === "mafia" ? "role-mafia" : "role-villager";
  const roleText =
    playerRole === "mafia"
      ? `YOU: MAFIA${partnerName ? ` · Partner: ${partnerName}` : ""}`
      : playerRole === "villager"
      ? "YOU: VILLAGER"
      : "—";

  return (
    <header
      className="flex items-center px-6 gap-6 z-10"
      style={{
        height: 64,
        background: "var(--color-surface)",
        borderBottom: "1px solid var(--color-border)",
        position: "sticky",
        top: 0,
      }}
    >
      {/* Left — round + phase */}
      <div className="flex items-center gap-2 min-w-[200px]">
        {isDiscussionOpen && (
          <span
            className="inline-block w-0.5 h-5 rounded-full animate-pulse"
            style={{ background: "var(--color-accent)" }}
          />
        )}
        <span
          className="text-sm tracking-wide uppercase font-semibold"
          style={{ color: isDiscussionOpen ? "var(--color-text)" : "var(--color-text-muted)" }}
        >
          {label}
        </span>
      </div>

      {/* Center — your role */}
      <div className="flex-1 flex justify-center">
        {playerRole && (
          <Badge variant={roleVariant}>{roleText}</Badge>
        )}
      </div>

      {/* Right — roster chips */}
      <div className="flex items-center gap-2">
        {living.map((slot) => (
          <RosterChip
            key={slot}
            slot={slot}
            entry={roster[slot]}
            isHuman={slot === playerSlot}
            isDead={false}
          />
        ))}
        {dead.length > 0 && (
          <span
            className="w-px h-8 mx-1"
            style={{ background: "var(--color-border)" }}
          />
        )}
        {dead.map((slot) => (
          <RosterChip
            key={slot}
            slot={slot}
            entry={roster[slot]}
            isHuman={slot === playerSlot}
            isDead={true}
          />
        ))}
      </div>
    </header>
  );
}
