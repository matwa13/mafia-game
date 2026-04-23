import type { RosterEntry } from "../types";

interface RosterChipProps {
  slot: number;
  entry: RosterEntry;
  isHuman: boolean;
  isDead: boolean;
}

function personaColorVar(archetypeId?: string): string {
  if (!archetypeId) return "var(--color-border)";
  return `var(--persona-${archetypeId}, var(--color-border))`;
}

export function RosterChip({ entry, isHuman, isDead }: RosterChipProps) {
  const initial = entry.name.charAt(0).toUpperCase();
  const color = isHuman
    ? "var(--color-role-human)"
    : personaColorVar(entry.archetypeId);

  return (
    <div
      className="flex flex-col items-center gap-0.5"
      style={{ opacity: isDead ? 0.6 : 1 }}
      title={entry.name}
    >
      <div
        className="w-10 h-10 rounded-full flex items-center justify-center text-sm font-semibold select-none"
        style={{
          background: isDead ? "var(--color-role-dead)" : color,
          border: isHuman
            ? "2px solid var(--color-accent)"
            : isDead
            ? "2px solid var(--color-role-dead)"
            : `2px solid ${color}`,
          boxShadow: isHuman && !isDead
            ? "0 0 0 3px oklch(0.65 0.12 85 / 0.3)"
            : undefined,
          color: "var(--color-text)",
        }}
      >
        {initial}
      </div>
      <span
        className="text-xs"
        style={{
          color: isDead ? "var(--color-text-muted)" : "var(--color-text)",
          textDecoration: isDead ? "line-through" : undefined,
          maxWidth: 40,
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        }}
      >
        {entry.name}
      </span>
    </div>
  );
}
