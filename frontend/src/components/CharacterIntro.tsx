import { useStore } from "../store";
import { Badge } from "./primitives/Badge";
import { Button } from "./primitives/Button";
import type { RosterEntry } from "../types";

interface CharacterIntroProps {
  onStart: () => void;
}

function personaColorVar(archetypeId?: string): string {
  if (!archetypeId) return "var(--color-border)";
  return `var(--persona-${archetypeId}, var(--color-border))`;
}

export function CharacterIntro({ onStart }: CharacterIntroProps) {
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);
  const playerRole = useStore((s) => s.game.playerRole);
  const partnerName = useStore((s) => s.game.partnerName);

  const slots = Object.keys(roster)
    .map((k) => Number(k))
    .sort((a, b) => a - b);

  const roleVariant = playerRole === "mafia" ? "role-mafia" : "role-villager";
  const roleText =
    playerRole === "mafia"
      ? `YOU: MAFIA${partnerName ? ` · Partner: ${partnerName}` : ""}`
      : playerRole === "villager"
      ? "YOU: VILLAGER"
      : "—";

  return (
    <div className="min-h-screen flex flex-col">
      <header
        className="flex items-center justify-between px-6"
        style={{
          height: 64,
          background: "var(--color-surface)",
          borderBottom: "1px solid var(--color-border)",
        }}
      >
        <span
          className="text-sm tracking-wide uppercase font-semibold"
          style={{ color: "var(--color-text-muted)" }}
        >
          Meet the players
        </span>
        {playerRole && <Badge variant={roleVariant}>{roleText}</Badge>}
        <span className="w-[200px]" />
      </header>

      <main className="flex-1 flex flex-col items-center px-6 py-8 gap-8 overflow-y-auto">
        <div className="max-w-[960px] w-full">
          <h1
            className="text-2xl font-semibold mb-2"
            style={{ color: "var(--color-text)" }}
          >
            Before Night 1
          </h1>
          <p className="text-sm mb-8" style={{ color: "var(--color-text-muted)" }}>
            Six players at the table. Two are Mafia. When you're ready, the first night begins.
          </p>

          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {slots.map((slot) => (
              <CharacterCard
                key={slot}
                entry={roster[slot]}
                isHuman={slot === playerSlot}
              />
            ))}
          </div>
        </div>
      </main>

      <footer
        className="flex items-center justify-end px-6 py-4"
        style={{
          background: "var(--color-surface)",
          borderTop: "1px solid var(--color-border)",
        }}
      >
        <Button variant="primary" size="lg" onClick={onStart}>
          Begin Night 1
        </Button>
      </footer>
    </div>
  );
}

function CharacterCard({
  entry,
  isHuman,
}: {
  entry: RosterEntry;
  isHuman: boolean;
}) {
  const color = isHuman
    ? "var(--color-role-human)"
    : personaColorVar(entry.archetypeId);
  const initial = entry.name.charAt(0).toUpperCase();

  return (
    <div
      className="rounded-md p-4 flex gap-4"
      style={{
        background: "var(--color-surface-raised)",
        border: isHuman
          ? "2px solid var(--color-accent)"
          : "1px solid var(--color-border)",
        boxShadow: isHuman
          ? "0 0 0 3px oklch(0.65 0.12 85 / 0.2)"
          : undefined,
      }}
    >
      <div
        className="w-12 h-12 rounded-full flex items-center justify-center text-base font-semibold shrink-0 select-none"
        style={{
          background: color,
          color: "var(--color-text)",
        }}
      >
        {initial}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-2">
          <span
            className="font-semibold text-base truncate"
            style={{ color: "var(--color-text)" }}
          >
            {entry.name}
          </span>
          {isHuman && (
            <span
              className="text-xs uppercase tracking-wide"
              style={{ color: "var(--color-accent)" }}
            >
              You
            </span>
          )}
        </div>
        {!isHuman && entry.archetypeLabel && (
          <div
            className="text-xs uppercase tracking-wide mt-0.5"
            style={{ color: "var(--color-text-muted)" }}
          >
            {entry.archetypeLabel}
          </div>
        )}
        {!isHuman && entry.voiceBlurb && (
          <p
            className="text-sm italic mt-2 leading-snug"
            style={{ color: "var(--color-text)" }}
          >
            &ldquo;{entry.voiceBlurb}&rdquo;
          </p>
        )}
        {isHuman && (
          <p
            className="text-sm mt-2"
            style={{ color: "var(--color-text-muted)" }}
          >
            That's you. The only human at the table.
          </p>
        )}
      </div>
    </div>
  );
}
