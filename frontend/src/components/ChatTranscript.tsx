import { useEffect, useRef } from "react";
import { useStore } from "../store";
import { ChatBubble } from "./ChatBubble";
import { SystemMessage } from "./SystemMessage";

export function ChatTranscript() {
  const messages = useStore((s) => s.chat.messages);
  const streaming = useStore((s) => s.chat.streaming);
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);

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

  const streamingEntries = Object.entries(streaming);

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
      {messages.map((msg, i) => {
        const entry = roster[msg.fromSlot];
        const isHuman = msg.fromSlot === playerSlot || msg.kind === "human";
        const isDead = entry ? !entry.alive : false;

        if (msg.kind === "system") {
          return <SystemMessage key={i} text={msg.text} />;
        }

        return (
          <ChatBubble
            key={i}
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
      })}

      {streamingEntries.map(([key, entry]) => {
        const rosterEntry = roster[entry.fromSlot];
        const isHuman = entry.fromSlot === playerSlot;
        return (
          <ChatBubble
            key={`streaming-${key}`}
            speaker={{
              name: rosterEntry?.name ?? String(entry.fromSlot),
              personaColor: rosterEntry?.personaColor,
              isHuman,
            }}
            content={entry.text}
            isStreaming
          />
        );
      })}
    </div>
  );
}
