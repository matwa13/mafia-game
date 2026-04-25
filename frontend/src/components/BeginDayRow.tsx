import { useStore } from "../store";
import { Button } from "./primitives/Button";

/**
 * Sticky-bottom Begin Day → gate row. Visible whenever phase === "night".
 *
 * Per UI-SPEC §7.6 / D-NU-02 — the button stays disabled until the
 * orchestrator emits `game_night_ready_for_day` (set by Plan 02's
 * `night.ready_for_day` mapping). Both Villager and Mafia humans see this
 * row; dead humans can still click it (they're not stranded behind a click
 * gate they can't trigger).
 */
export function BeginDayRow() {
  const awaitingBeginDay = useStore((s) => s.night.awaitingBeginDay);
  const round = useStore((s) => s.game.round);

  function handleBeginDay() {
    if (!awaitingBeginDay) return;
    useStore.getState().send("game_begin_day", { round });
  }

  return (
    <div
      className="flex flex-col gap-2 p-3 border-t"
      style={{
        borderColor: "var(--color-border)",
        background: "var(--color-surface)",
        position: "sticky",
        bottom: 0,
      }}
    >
      {!awaitingBeginDay && (
        <p
          className="text-sm text-center"
          role="status"
          style={{ color: "var(--color-text-muted)" }}
        >
          Waiting for night to resolve...
        </p>
      )}
      <Button
        variant="primary"
        size="md"
        disabled={!awaitingBeginDay}
        onClick={handleBeginDay}
        aria-label="Begin Day"
        title={!awaitingBeginDay ? "Waiting for night to resolve" : undefined}
      >
        Begin Day →
      </Button>
    </div>
  );
}
