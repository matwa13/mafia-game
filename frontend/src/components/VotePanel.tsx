import { useState } from "react";
import { useStore } from "../store";
import { Button } from "./primitives/Button";
import { VoteBubble } from "./VoteBubble";

export function VotePanel() {
  const game = useStore((s) => s.game);
  const vote = useStore((s) => s.vote);
  const awaitingNextDay = useStore((s) => s.game.awaitingNextDay);
  const [selectedSlot, setSelectedSlot] = useState<number | null>(null);
  const [voted, setVoted] = useState(false);

  const { roster, playerSlot, round } = game;
  const playerEntry = playerSlot != null ? roster[playerSlot] : undefined;
  const playerDead = playerEntry ? !playerEntry.alive : false;
  const livingPlayers = Object.entries(roster)
    .filter(([slot, r]) => r.alive && Number(slot) !== playerSlot)
    .map(([slot, r]) => ({ slot: Number(slot), entry: r }));

  const npcVotesIn = vote.perVoter.filter((v) => v.from_slot !== playerSlot).length;
  const notYetVotedCount = livingPlayers.length - npcVotesIn;

  function castVote() {
    if (selectedSlot == null || voted) return;
    useStore.getState().send("game_vote_cast", { vote_for_slot: selectedSlot, round });
    setVoted(true);
  }

  function startNextDay() {
    if (!awaitingNextDay) return;
    useStore.getState().send("game_advance_phase", { round });
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
      className="flex-1 flex flex-col items-center gap-6 p-6 overflow-y-auto"
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

      {/* Vote bubbles — one per living NPC. Each starts in "Thinking..."
          state and flips to the revealed reasoning as its vote arrives. */}
      <div className="flex flex-col gap-3 w-full items-center">
        {livingPlayers.map(({ slot, entry }) => {
          const cast = vote.perVoter.find((v) => v.from_slot === slot);
          const targetEntry = cast ? roster[cast.vote_for_slot ?? -1] : undefined;
          return (
            <VoteBubble
              key={slot}
              voterName={entry.name}
              personaColor={entry.personaColor}
              thinking={!cast}
              targetName={targetEntry?.name}
              reasoning={cast?.reasoning}
            />
          );
        })}
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

      {/* Dead player — no voting rights */}
      {playerDead && !vote.revealed && (
        <p
          className="text-sm text-center"
          role="status"
          style={{ color: "var(--color-text-muted)" }}
        >
          You are dead. You no longer have voting rights.
        </p>
      )}

      {/* Your vote selector — only for living player, pre-reveal */}
      {!playerDead && !voted && !vote.revealed && (
        <div className="flex flex-col gap-3 w-full max-w-[560px]">
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

      {/* Start next day — only shown during the vote phase. Disabled until
          the orchestrator signals `day.vote_complete` (reveal + lynch done). */}
      <Button
        variant="primary"
        size="md"
        disabled={!awaitingNextDay}
        onClick={startNextDay}
        aria-label="Start next day"
        title={!awaitingNextDay ? "Waiting for all votes to come in" : undefined}
      >
        Start next day →
      </Button>
    </div>
  );
}
