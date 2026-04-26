import { useCallback, useEffect, useState } from "react";
import { useStore } from "./store";
import { useGameSocket } from "./ws";
import { StatusBanner } from "./components/StatusBanner";
import { ChatTranscript } from "./components/ChatTranscript";
import { InterjectionInput } from "./components/InterjectionInput";
import { VotePanel } from "./components/VotePanel";
import { LastWordsCard } from "./components/LastWordsCard";
import { EliminationRibbon } from "./components/EliminationRibbon";
import { EndGameBanner } from "./components/EndGameBanner";
import { CharacterIntro } from "./components/CharacterIntro";
import { NightOverlay } from "./components/NightOverlay";
import { NightPicker } from "./components/NightPicker";
import { BeginDayRow } from "./components/BeginDayRow";
import { DevDrawer } from "./components/DevDrawer";
import { Button } from "./components/primitives/Button";

export default function App() {
  const applyFrame = useStore((s) => s.applyFrame);
  const setSend = useStore((s) => s.setSend);
  const { send } = useGameSocket(
    useCallback((topic, data) => applyFrame(topic, data), [applyFrame])
  );
  useEffect(() => { setSend(send); }, [send, setSend]);

  const phase = useStore((s) => s.game.phase);
  const lastElim = useStore((s) => s.game.lastEliminated);
  const playerRole = useStore((s) => s.game.playerRole);
  const playerSlot = useStore((s) => s.game.playerSlot);
  const roster = useStore((s) => s.game.roster);
  const devMode = useStore((s) => s.game.devMode);

  if (phase === null || phase === undefined) {
    return (
      <SetupScreen
        onStart={(playerName, seed) => {
          // Persist the name on the store before sending so Start New Game
          // (D-EG-03) can re-use it without re-prompting the player.
          useStore.setState((s) => ({ game: { ...s.game, playerName } }));
          const payload: { name: string; seed?: number } = { name: playerName };
          if (seed !== undefined) payload.seed = seed;
          send("game_start", payload);
        }}
      />
    );
  }

  if (phase === "intro") {
    return <CharacterIntro onStart={() => send("game_start_game", {})} />;
  }

  // Dead-Mafia fallback: a Mafia-human who's been eliminated falls through
  // to the Villager-style overlay so they can still observe + click Begin
  // Day, but cannot send mafia_chat or pick a target.
  const playerEntry =
    roster && playerSlot != null ? roster[playerSlot] : undefined;
  const playerDead = playerEntry ? !playerEntry.alive : false;

  return (
    <div className="h-screen flex flex-col">
      <StatusBanner />
      {lastElim && <EliminationRibbon victimName={lastElim.name} />}
      <main className="flex-1 flex min-h-0">
        <div className="flex-1 min-w-0 flex flex-col">
          {phase === "day" && (
            <>
              <ChatTranscript />
              <InterjectionInput />
            </>
          )}
          {phase === "night" && playerRole === "villager" && <NightOverlay />}
          {phase === "night" && playerRole === "mafia" &&
            (playerDead ? <NightOverlay /> : <NightPicker />)}
          {phase === "vote" && <VotePanel />}
          {phase === "reveal" && <VotePanel />}
        </div>
        {devMode && <DevDrawer />}
      </main>
      {phase === "night" && <BeginDayRow />}
      <LastWordsCardWrapper />
      {phase === "ended" && <EndGameBanner />}
    </div>
  );
}

function SetupScreen({ onStart }: { onStart: (name: string, seed?: number) => void }) {
  const [name, setName] = useState("");
  const [seedInput, setSeedInput] = useState("");
  const devMode = useStore((s) => s.game.devMode);

  const trimmed = name.trim();
  const canStart = trimmed.length > 0 && trimmed.length <= 32;
  const seedInvalid = devMode && seedInput !== "" && !/^\d+$/.test(seedInput);

  function handleStart() {
    if (!canStart) return;
    const parsedSeed = devMode && /^\d+$/.test(seedInput.trim())
      ? parseInt(seedInput.trim(), 10)
      : undefined;
    onStart(trimmed, parsedSeed);
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter") {
      e.preventDefault();
      handleStart();
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center">
      <div className="max-w-[560px] w-full text-center space-y-8 px-4">
        <h1 className="text-2xl font-semibold">MAFIA — MVP</h1>
        <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
          5 NPCs. One human. One vote.
        </p>
        <div className="flex flex-col items-center gap-3">
          <label
            htmlFor="player-name"
            className="text-sm"
            style={{ color: "var(--color-text-muted)" }}
          >
            Your name (required)
          </label>
          <input
            id="player-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="e.g. Alex"
            maxLength={32}
            autoFocus
            className="w-full max-w-[320px] rounded-md px-3 py-2 text-base outline-none focus-visible:ring-2"
            style={{
              background: "var(--color-surface-raised)",
              color: "var(--color-text)",
              border: "1px solid var(--color-border)",
              outlineColor: "var(--color-accent)",
            }}
          />
          {devMode && (
            <>
              <label
                htmlFor="seed-input"
                className="text-sm"
                style={{ color: "var(--color-text-muted)" }}
              >
                Seed (optional)
              </label>
              <input
                id="seed-input"
                type="text"
                value={seedInput}
                onChange={(e) => setSeedInput(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="e.g. 42 (leave empty for random)"
                className="w-full max-w-[320px] rounded-md px-3 py-2 text-base outline-none focus-visible:ring-2"
                style={{
                  background: "var(--color-surface-raised)",
                  color: "var(--color-text)",
                  border: seedInvalid
                    ? "1px solid var(--color-danger)"
                    : "1px solid var(--color-border)",
                  outlineColor: "var(--color-accent)",
                }}
              />
            </>
          )}
          <Button variant="primary" onClick={handleStart} disabled={!canStart}>
            Start new game
          </Button>
        </div>
        <div className="text-sm space-y-1" style={{ color: "var(--color-text-muted)" }}>
          <p>2 Mafia and 4 Villagers (you are one of 6)</p>
          <p>Night: Mafia picks a target. Day: town votes.</p>
          <p>Majority wins when the other side is out.</p>
        </div>
      </div>
    </div>
  );
}

function LastWordsCardWrapper() {
  const latestLastWords = useStore((s) => {
    const msgs = s.chat.messages;
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].kind === "last_words") return msgs[i];
    }
    return null;
  });
  if (!latestLastWords) return null;
  return (
    <LastWordsCard
      victimName={latestLastWords.fromName}
      text={latestLastWords.text}
    />
  );
}
