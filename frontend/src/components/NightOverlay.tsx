import { useStore } from "../store";
import { RosterChip } from "./RosterChip";

/**
 * Full-screen Villager-night view (also rendered for dead Mafia humans).
 *
 * Per UI-SPEC §7.1 / D-NU-01 — purely informational while the Mafia plot
 * happens off-screen. No input affordances; the only player action while
 * this is visible is clicking Begin Day in BeginDayRow once the orchestrator
 * signals night.ready_for_day.
 */
export function NightOverlay() {
  const round = useStore((s) => s.game.round);
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);

  return (
    <div
      role="region"
      aria-label="Night phase — town sleeping"
      className="flex-1 flex flex-col items-center justify-center gap-8 p-6"
      style={{
        animationName: "nightOverlayEnter",
        animationDuration: "300ms",
        animationTimingFunction: "ease-out",
        animationFillMode: "both",
      }}
    >
      <div
        className="max-w-[480px] w-full rounded-lg p-8 flex flex-col items-center gap-4"
        style={{
          background: "var(--color-night-surface)",
          boxShadow: "var(--shadow-2)",
        }}
      >
        <span aria-hidden="true" className="text-2xl">🌙</span>
        <h2
          className="text-lg font-semibold text-center"
          style={{ color: "var(--color-text)" }}
        >
          Night {round} — the town is quiet.
        </h2>
        <p
          className="text-sm text-center"
          style={{ color: "var(--color-text-muted)" }}
        >
          The Mafia are choosing their target.
        </p>
      </div>

      {/* Dimmed roster — view-only during night. */}
      <div
        className="flex items-center gap-2 flex-wrap justify-center"
        aria-label="Players (night — view only)"
        style={{ opacity: 0.4 }}
      >
        {Object.entries(roster).map(([slot, entry]) => (
          <RosterChip
            key={slot}
            slot={Number(slot)}
            entry={entry}
            isHuman={Number(slot) === playerSlot}
            isDead={!entry.alive}
          />
        ))}
      </div>
    </div>
  );
}
