import { useStore } from "../store";
import { Dialog } from "./primitives/Dialog";
import { Button } from "./primitives/Button";
import { ChatTranscript } from "./ChatTranscript";

export function EndGameBanner() {
  const game = useStore((s) => s.game);
  const { winner, roster, playerSlot } = game;
  const playerName = useStore((s) => s.game.playerName);

  const isVillageWin = winner === "villager";
  const titleColor = isVillageWin ? "var(--color-success)" : "var(--color-danger)";
  const titleText = isVillageWin ? "VILLAGE WINS." : "MAFIA WINS.";

  const rosterEntries = Object.entries(roster).map(([slot, entry]) => ({
    slot: Number(slot),
    entry,
    isHuman: Number(slot) === playerSlot,
  }));

  return (
    <Dialog open>
      {/* Backdrop */}
      <div
        className="fixed inset-0 flex items-center justify-center"
        style={{ background: "rgba(0,0,0,0.6)", zIndex: 50 }}
      >
        <div
          className="rounded-lg p-8 flex flex-col gap-6 w-full max-w-[680px] max-h-[90vh] overflow-y-auto"
          style={{
            background: "var(--color-surface-raised)",
            boxShadow: "var(--shadow-2)",
            animationName: "endGameEnter",
            animationDuration: "300ms",
            animationTimingFunction: "ease-out",
            animationFillMode: "both",
          }}
        >
          {/* Title */}
          <h2
            className="text-2xl font-semibold tracking-tight text-center"
            style={{ color: titleColor }}
          >
            {titleText}
          </h2>

          {/* Roster reveal */}
          <div className="flex flex-col gap-1">
            <p className="text-sm mb-2" style={{ color: "var(--color-text-muted)" }}>
              Final roster:
            </p>
            {rosterEntries.map(({ slot, entry, isHuman }) => {
              const roleLower = entry.role ?? "unknown";
              const roleColor =
                roleLower === "mafia"
                  ? "var(--color-role-mafia)"
                  : "var(--color-role-villager)";
              return (
                <div
                  key={slot}
                  className="flex items-center gap-3 px-2 py-1.5 rounded"
                  style={{
                    borderLeft: isHuman ? "2px solid var(--color-accent)" : "2px solid transparent",
                    background: isHuman ? "var(--color-surface)" : undefined,
                  }}
                >
                  <span
                    className="w-2.5 h-2.5 rounded-full flex-shrink-0"
                    style={{
                      background: isHuman
                        ? "var(--color-role-human)"
                        : entry.alive
                        ? "var(--color-text-muted)"
                        : "var(--color-role-dead)",
                    }}
                  />
                  <span className="text-base flex-1">
                    {entry.name}
                  </span>
                  <span
                    className="text-sm font-semibold capitalize"
                    style={{ color: roleColor }}
                  >
                    {roleLower}
                  </span>
                  <span
                    className="text-sm"
                    style={{ color: entry.alive ? "var(--color-success)" : "var(--color-text-muted)" }}
                  >
                    {entry.alive ? "alive" : "eliminated"}
                  </span>
                </div>
              );
            })}
          </div>

          {/* Phase 4 — full game transcript scrollback. For Mafia-humans this
              includes mafia_chat lines (wine bg) interleaved with public chat
              by seq. For Villager-humans the merged set degenerates to public
              chat only because they never received any mafia_chat events. */}
          <div className="flex flex-col gap-2">
            <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
              Full game transcript:
            </p>
            <div
              role="log"
              style={{
                maxHeight: 360,
                overflowY: "auto",
                background: "var(--color-surface)",
                borderRadius: 8,
                padding: 12,
              }}
            >
              <ChatTranscript showMafiaChat />
            </div>
          </div>

          {/* CTA — Phase 4: Start New Game wires through resetForNewGame
              (preserves playerName per D-EG-03) and dispatches game_start
              with the same name. No page reload — the WS connection is
              re-used and a fresh game session is created server-side. */}
          <div className="flex justify-center">
            <Button
              variant="primary"
              size="lg"
              onClick={() => {
                const name = playerName ?? "";
                useStore.getState().resetForNewGame(name);
                useStore.getState().send("game_start", { name });
              }}
            >
              Start New Game
            </Button>
          </div>
        </div>
      </div>
    </Dialog>
  );
}
