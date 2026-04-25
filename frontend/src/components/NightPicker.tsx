import { useStore } from "../store";
import { Button } from "./primitives/Button";
import { SideChat } from "./SideChat";

/**
 * Mafia-human night UI: side-chat above, kill-picker chip row + Lock target
 * CTA below. Per UI-SPEC §7.2 / D-NU-04.
 *
 * Partner-dead variant (D-SC-06): when the partner has been eliminated, the
 * side-chat is omitted entirely and the picker is presented alone with a
 * "you plot alone" subtitle.
 *
 * App.tsx routes dead Mafia humans to NightOverlay instead of this picker.
 */
export function NightPicker() {
  const round = useStore((s) => s.game.round);
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);
  const partnerName = useStore((s) => s.game.partnerName);
  const partnerSuggestedSlot = useStore((s) => s.sideChat.partnerSuggestedSlot);
  const sideChatMessages = useStore((s) => s.sideChat.messages);
  const locked = useStore((s) => s.night.locked);
  const pickedSlot = useStore((s) => s.night.pickedSlot);

  // Find partner slot by scanning the roster for the other Mafia. The
  // orchestrator includes role on the roster only for the Mafia-human's
  // own view (player_role === 'mafia') — Villager-humans don't see roles.
  let partnerSlot: number | null = null;
  for (const [slotStr, entry] of Object.entries(roster)) {
    const slot = Number(slotStr);
    if (slot !== playerSlot && entry.role === "mafia") {
      partnerSlot = slot;
      break;
    }
  }
  const partnerEntry = partnerSlot != null ? roster[partnerSlot] : undefined;
  const partnerAlive = partnerEntry ? !!partnerEntry.alive : false;

  // Living non-Mafia targets only — excludes self, partner (Mafia), and dead.
  const livingTargets = Object.entries(roster)
    .map(([slotStr, entry]) => ({ slot: Number(slotStr), entry }))
    .filter(
      ({ slot, entry }) =>
        entry.alive && entry.role !== "mafia" && slot !== playerSlot,
    );

  // Strict-alternation derivation: partner is thinking when the most-recent
  // sideChat msg is from the human (or sideChat is empty AND partner is
  // alive — the partner opens the round per D-SC-01).
  const lastMsg = sideChatMessages[sideChatMessages.length - 1];
  const partnerThinking =
    partnerAlive && (lastMsg == null || lastMsg.fromSlot === playerSlot);

  function setPickedSlot(slot: number | null) {
    useStore.setState((s) => ({ night: { ...s.night, pickedSlot: slot } }));
  }

  function lockTarget() {
    if (pickedSlot == null || locked) return;
    useStore.setState((s) => ({ night: { ...s.night, locked: true } }));
    useStore
      .getState()
      .send("game_night_pick", { target_slot: pickedSlot, round });
  }

  return (
    <div className="flex-1 flex flex-col items-center px-4 py-6 overflow-y-auto">
      <div
        className="max-w-[560px] w-full rounded-lg flex flex-col"
        style={{
          background: "var(--color-surface)",
          boxShadow: "var(--shadow-2)",
        }}
      >
        <div className="px-6 pt-5 pb-3 flex flex-col gap-1">
          <h2
            className="text-lg font-semibold"
            style={{ color: "var(--color-text)" }}
          >
            MAFIA NIGHT {round}
          </h2>
          <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
            {partnerAlive
              ? `You and ${partnerName ?? "your partner"}`
              : `Your partner ${partnerName ?? ""} was eliminated — you plot alone.`}
          </p>
        </div>
        <div
          className="border-t"
          style={{ borderColor: "var(--color-border)" }}
        />

        {partnerAlive && (
          <div style={{ minHeight: 200, maxHeight: 360 }}>
            <SideChat partnerThinking={partnerThinking} />
          </div>
        )}

        <div
          className="border-t"
          style={{ borderColor: "var(--color-border)" }}
        />

        <div
          className="px-6 py-4 flex flex-col gap-3"
          style={{ background: "var(--color-surface-raised)" }}
        >
          <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
            Choose your target
          </p>
          <div
            className="flex flex-wrap gap-2"
            role="radiogroup"
            aria-label="Kill target"
          >
            {livingTargets.map(({ slot, entry }) => {
              const selected = pickedSlot === slot;
              const isPartnerSuggestion =
                partnerSuggestedSlot === slot && !selected;
              return (
                <button
                  key={slot}
                  role="radio"
                  aria-checked={selected}
                  onClick={() => !locked && setPickedSlot(slot)}
                  disabled={locked}
                  className="px-3 py-1.5 rounded-md text-sm font-semibold cursor-pointer transition-colors disabled:cursor-not-allowed"
                  style={{
                    background: selected
                      ? "var(--color-surface-raised)"
                      : "var(--color-surface)",
                    border: selected
                      ? "2px solid var(--color-accent)"
                      : isPartnerSuggestion
                        ? "2px dashed var(--color-accent)"
                        : "2px solid var(--color-border)",
                    color: "var(--color-text)",
                    outline: "none",
                  }}
                >
                  {entry.name}
                  {isPartnerSuggestion && (
                    <span
                      className="block text-xs"
                      style={{ color: "var(--color-text-muted)" }}
                    >
                      Partner picks: {entry.name}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          <Button
            variant="primary"
            size="lg"
            disabled={pickedSlot == null || locked}
            onClick={lockTarget}
            aria-label="Lock target"
          >
            {locked
              ? `Locked — ${pickedSlot != null ? (roster[pickedSlot]?.name ?? "—") : "—"}`
              : "Lock target →"}
          </Button>
        </div>
      </div>
    </div>
  );
}
