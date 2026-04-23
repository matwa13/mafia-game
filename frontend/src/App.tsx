import { useCallback, useEffect } from "react";
import { useStore } from "./store";
import { useGameSocket } from "./ws";
import { StatusBanner } from "./components/StatusBanner";
import { ChatTranscript } from "./components/ChatTranscript";
import { InterjectionInput } from "./components/InterjectionInput";
import { VotePanel } from "./components/VotePanel";
import { LastWordsCard } from "./components/LastWordsCard";
import { EliminationRibbon } from "./components/EliminationRibbon";
import { EndGameBanner } from "./components/EndGameBanner";
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

  if (phase === null || phase === undefined) {
    return <SetupScreen onStart={() => send("game_start", { seed: 3 })} />;
  }

  return (
    <div className="min-h-screen flex flex-col">
      <StatusBanner />
      {lastElim && <EliminationRibbon victimName={lastElim.name} />}
      <main className="flex-1 flex">
        {(phase === "day" || phase === "night") && (
          <>
            <ChatTranscript />
            <InterjectionInput />
          </>
        )}
        {phase === "vote" && <VotePanel />}
        {phase === "reveal" && <VotePanel />}
      </main>
      <LastWordsCardWrapper />
      {phase === "ended" && <EndGameBanner />}
    </div>
  );
}

function SetupScreen({ onStart }: { onStart: () => void }) {
  return (
    <div className="min-h-screen flex items-center justify-center">
      <div className="max-w-[560px] text-center space-y-8">
        <h1 className="text-2xl font-semibold">MAFIA — MVP</h1>
        <p className="text-sm" style={{ color: "var(--color-text-muted)" }}>
          5 NPCs. One human. One vote.
        </p>
        <Button variant="primary" onClick={onStart}>Start new game</Button>
        <div className="text-sm text-left space-y-1" style={{ color: "var(--color-text-muted)" }}>
          <p>• 2 Mafia and 4 Villagers (you are one of 6)</p>
          <p>• Night: Mafia picks a target. Day: town votes.</p>
          <p>• Majority wins when the other side is out.</p>
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
