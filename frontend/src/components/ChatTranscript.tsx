import { useEffect, useMemo, useRef } from "react";
import { useStore } from "../store";
import { ChatBubble } from "./ChatBubble";
import { SystemMessage } from "./SystemMessage";

export function ChatTranscript() {
  const messages = useStore((s) => s.chat.messages);
  const streaming = useStore((s) => s.chat.streaming);
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);

  // Unified render list: committed messages + live streaming bubbles,
  // both sorted by (round, seq). Orchestrator reserves a seq for each NPC
  // turn at the moment the turn starts and echoes it on chat.chunk events,
  // so a streaming bubble renders at its eventual committed slot while it's
  // still being typed out — no visual jump when the NPC commits.
  //
  // A user interjection during an NPC turn commits at a higher seq than the
  // in-flight NPC, so the NPC's (streaming then committed) bubble stays
  // above the user's interjection the whole time.
  //
  // System messages with no seq stay in their insertion position via the
  // stable sort fallback.
  type RenderItem =
    | { kind: "committed"; round: number; seq?: number; msg: (typeof messages)[number]; id: string }
    | { kind: "streaming"; round: number; seq?: number; streamKey: string; entry: (typeof streaming)[string] };

  const renderItems = useMemo<RenderItem[]>(() => {
    const items: RenderItem[] = [];
    messages.forEach((msg, i) => {
      items.push({
        kind: "committed",
        round: msg.round,
        seq: msg.seq,
        msg,
        id: `m-${i}-${msg.seq ?? "x"}`,
      });
    });
    Object.entries(streaming).forEach(([streamKey, entry]) => {
      items.push({
        kind: "streaming",
        round: entry.round,
        seq: entry.seq,
        streamKey,
        entry,
      });
    });
    items.sort((a, b) => {
      if (a.round !== b.round) return a.round - b.round;
      if (a.seq != null && b.seq != null) return a.seq - b.seq;
      return 0;
    });
    return items;
  }, [messages, streaming]);

  const scrollRef = useRef<HTMLDivElement>(null);
  const stuckToBottom = useRef(true);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !stuckToBottom.current) return;
    el.scrollTop = el.scrollHeight;
  }, [messages, streaming]);

  function onScroll() {
    const el = scrollRef.current;
    if (!el) return;
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    stuckToBottom.current = distanceFromBottom < 40;
  }

  return (
    <div
      ref={scrollRef}
      onScroll={onScroll}
      role="log"
      aria-live="polite"
      aria-atomic="false"
      className="flex-1 overflow-y-auto flex flex-col gap-4 p-4"
      style={{ maxWidth: 720, margin: "0 auto", width: "100%" }}
    >
      {renderItems.map((item) => {
        if (item.kind === "committed") {
          const msg = item.msg;
          const entry = roster[msg.fromSlot];
          const isHuman = msg.fromSlot === playerSlot || msg.kind === "human";
          const isDead = entry ? !entry.alive : false;

          if (msg.kind === "system") {
            return <SystemMessage key={item.id} text={msg.text} />;
          }

          return (
            <ChatBubble
              key={item.id}
              speaker={{
                name: msg.fromName,
                personaColor: entry?.personaColor,
                isHuman,
                isDead,
              }}
              content={msg.text}
              isInterjection={msg.kind === "human" && msg.fromSlot === playerSlot}
              isLastWords={msg.kind === "last_words"}
            />
          );
        }

        // streaming bubble — renders at its seq slot so it does not jump
        // when the NPC eventually commits.
        const streamEntry = item.entry;
        const rosterEntry = roster[streamEntry.fromSlot];
        const isHuman = streamEntry.fromSlot === playerSlot;
        return (
          <ChatBubble
            key={`streaming-${item.streamKey}`}
            speaker={{
              name: rosterEntry?.name ?? String(streamEntry.fromSlot),
              personaColor: rosterEntry?.personaColor,
              isHuman,
            }}
            content={streamEntry.text}
            isStreaming
          />
        );
      })}
    </div>
  );
}
