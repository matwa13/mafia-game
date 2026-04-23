import { useState } from "react";
import { useStore } from "../store";
import { Button } from "./primitives/Button";
import { VoteRevealCard } from "./VoteRevealCard";

export function VotePanel() {
  const game = useStore((s) => s.game);
  const vote = useStore((s) => s.vote);
  const [selectedSlot, setSelectedSlot] = useState<number | null>(null);
  const [voted, setVoted] = useState(false);

  const { roster, playerSlot, round } = game;
  const livingPlayers = Object.entries(roster)
    .filter(([slot, r]) => r.alive && Number(slot) !== playerSlot)
    .map(([slot, r]) => ({ slot: Number(slot), entry: r }));

  const notYetVotedCount = livingPlayers.length - vote.perVoter.length;

  function castVote() {
    if (selectedSlot == null || voted) return;
    useStore.getState().send("game_vote_cast", { vote_for_slot: selectedSlot, round });
    setVoted(true);
  }

  // Tally top slot
  const tallyEntries = Object.entries(vote.tally).map(([k, v]) => ({
    slot: Number(k),
    count: Number(v),
  }));
  tallyEntries.sort((a, b) => b.count - a.count);
  const topCount = tallyEntries[0]?.count ?? 0;
  const topSlots = tallyEntries.filter((e) => e.count === topCount).map((e) => e.slot);
  const isTie = topSlots.length > 1;

  return (
    <div
      className="flex-1 flex flex-col items-center gap-6 p-6"
      style={{ color: "var(--color-text)" }}
    >
      <h2 className="text-lg font-semibold">VOTE — DAY {round}</h2>

      {!vote.revealed && (
        <p
          className="text-sm"
          role="status"
          style={{ color: "var(--color-text-muted)" }}
        >
          {notYetVotedCount > 0
            ? `Waiting on ${notYetVotedCount} vote${notYetVotedCount !== 1 ? "s" : ""}...`
            : "All votes in — awaiting reveal..."}
        </p>
      )}

      {/* Voter cards */}
      <div className="flex flex-wrap gap-3 justify-center">
        {vote.revealed
          ? vote.perVoter.map((v, i) => {
              const targetEntry = roster[v.vote_for_slot ?? -1];
              const voterEntry = roster[v.from_slot];
              return (
                <VoteRevealCard
                  key={v.from_slot}
                  voter={v}
                  targetName={targetEntry?.name ?? "—"}
                  personaColor={voterEntry?.personaColor}
                  index={i}
                />
              );
            })
          : livingPlayers.map(({ slot, entry }) => (
              <div
                key={slot}
                className="flex flex-col items-center justify-center rounded-md"
                style={{
                  width: 140,
                  height: 180,
                  background: "var(--color-surface)",
                  boxShadow: "var(--shadow-1)",
                  border: "1px solid var(--color-border)",
                }}
              >
                <span
                  className="text-3xl"
                  style={{ color: "var(--color-text-muted)" }}
                >
                  ?
                </span>
                <span className="text-sm mt-2" style={{ color: "var(--color-text-muted)" }}>
                  {entry.name}
                </span>
              </div>
            ))}
      </div>

      {/* Tally row after reveal */}
      {vote.revealed && (
        <div className="flex flex-col items-center gap-2 mt-2">
          {isTie || vote.tied ? (
            <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
              Tie — no elimination.
            </p>
          ) : (
            tallyEntries.map(({ slot, count }) => {
              const name = roster[slot]?.name ?? String(slot);
              const isTop = slot === topSlots[0];
              return (
                <div key={slot} className="flex items-center gap-3">
                  <span
                    className="text-base font-semibold"
                    style={{ color: isTop ? "var(--color-danger)" : "var(--color-text)" }}
                  >
                    {name}: {count}
                  </span>
                  {isTop && (
                    <span
                      className="text-xs px-1 py-0.5 rounded"
                      style={{
                        color: "var(--color-danger)",
                        border: "1px solid var(--color-danger)",
                      }}
                    >
                      eliminated
                    </span>
                  )}
                </div>
              );
            })
          )}
        </div>
      )}

      {/* Your vote selector */}
      {!voted && !vote.revealed && (
        <div className="flex flex-col gap-3 w-full max-w-[480px]">
          <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
            Your vote:
          </p>
          <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Vote target">
            {livingPlayers.map(({ slot, entry }) => {
              const selected = selectedSlot === slot;
              return (
                <button
                  key={slot}
                  role="radio"
                  aria-checked={selected}
                  onClick={() => setSelectedSlot(slot)}
                  className="px-3 py-1.5 rounded-md text-sm font-semibold cursor-pointer transition-colors"
                  style={{
                    background: selected ? "var(--color-surface-raised)" : "var(--color-surface)",
                    border: selected
                      ? "2px solid var(--color-accent)"
                      : "2px solid var(--color-border)",
                    color: "var(--color-text)",
                    outline: "none",
                  }}
                  onFocus={(e) =>
                    (e.currentTarget.style.boxShadow = `0 0 0 2px var(--color-accent)`)
                  }
                  onBlur={(e) => (e.currentTarget.style.boxShadow = "")}
                >
                  {entry.name}
                </button>
              );
            })}
          </div>
          <Button
            variant="primary"
            size="md"
            disabled={selectedSlot == null}
            onClick={castVote}
            aria-label="Cast vote"
          >
            Cast vote
          </Button>
        </div>
      )}

      {voted && !vote.revealed && (
        <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
          Vote cast — {roster[selectedSlot!]?.name ?? "—"}. Waiting for others...
        </p>
      )}
    </div>
  );
}
