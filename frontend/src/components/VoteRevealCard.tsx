import type { VotePerVoter } from "../types";

interface VoteRevealCardProps {
  voter: VotePerVoter;
  targetName: string;
  personaColor?: string;
  index: number;
}

export function VoteRevealCard({ voter, targetName, personaColor, index }: VoteRevealCardProps) {
  const color = personaColor ?? "var(--color-text-muted)";

  return (
    <div
      className="rounded-md p-4 flex flex-col gap-2"
      style={{
        width: 140,
        minHeight: 180,
        background: "var(--color-surface-raised)",
        boxShadow: "var(--shadow-2)",
        border: "1px solid var(--color-border)",
        animationName: "flipReveal",
        animationDuration: "500ms",
        animationTimingFunction: "ease-out",
        animationFillMode: "both",
        animationDelay: `${index * 50}ms`,
      }}
    >
      <div className="flex items-center gap-1">
        <span
          className="w-2.5 h-2.5 rounded-full flex-shrink-0"
          style={{ background: color }}
        />
        <span
          className="text-sm font-semibold truncate"
          style={{ borderBottom: `2px solid ${color}`, paddingBottom: 1 }}
        >
          {voter.from_name}
        </span>
      </div>
      <div className="h-px" style={{ background: "var(--color-border)" }} />
      <div className="text-lg font-semibold" style={{ color: "var(--color-text)" }}>
        → {targetName}
      </div>
      <div className="h-px" style={{ background: "var(--color-border)" }} />
      <p
        className="text-sm overflow-hidden"
        style={{
          color: "var(--color-text-muted)",
          display: "-webkit-box",
          WebkitLineClamp: 3,
          WebkitBoxOrient: "vertical",
        }}
      >
        "{voter.reasoning}"
      </p>
    </div>
  );
}
