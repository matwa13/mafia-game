import { useLayoutEffect, useRef, useState } from "react";
import { useStore } from "../store";
import { MafiaChatBubble } from "./MafiaChatBubble";

interface SideChatProps {
  /**
   * Strict alternation gate from parent (NightPicker). When true, the
   * partner is currently generating a reply and the input is locked —
   * matches the day-chat pattern of typing indicator instead of token
   * streaming, but applied to the side-channel.
   */
  partnerThinking: boolean;
}

const MAX_CHARS = 500;

/**
 * Mafia-human side-chat panel. Renders mafia_chat bubbles in seq order and
 * exposes a single-line input bound to `game_mafia_chat_send`. Disabled
 * whenever the human is dead or the partner is thinking (D-SC-03).
 */
export function SideChat({ partnerThinking }: SideChatProps) {
  const messages = useStore((s) => s.sideChat.messages);
  const round = useStore((s) => s.game.round);
  const playerSlot = useStore((s) => s.game.playerSlot);
  const playerEntry = useStore((s) =>
    s.game.playerSlot != null ? s.game.roster[s.game.playerSlot] : undefined,
  );
  const playerDead = playerEntry ? !playerEntry.alive : false;

  const bottomRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState("");

  useLayoutEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "auto", block: "end" });
  }, [messages, partnerThinking]);

  const inputDisabled = playerDead || partnerThinking;

  function handleSubmit() {
    const text = draft.trim().slice(0, MAX_CHARS);
    if (!text || inputDisabled) return;
    useStore.getState().send("game_mafia_chat_send", { text, round });
    setDraft("");
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter") {
      e.preventDefault();
      handleSubmit();
    }
  }

  return (
    <div className="flex flex-col h-full">
      <div
        role="log"
        aria-live="polite"
        aria-atomic="false"
        className="flex-1 overflow-y-auto flex flex-col gap-3 px-4 pt-4 pb-2"
        style={{
          background: "var(--color-night-surface)",
          minHeight: 200,
          maxHeight: 360,
        }}
      >
        {messages.map((msg) => (
          <MafiaChatBubble key={`mc-${msg.seq}`} message={msg} />
        ))}
        {partnerThinking && (
          <div
            className="text-sm italic px-2"
            style={{ color: "var(--color-text-muted)" }}
            aria-label="Partner is thinking"
          >
            Partner is thinking...
          </div>
        )}
        <div ref={bottomRef} aria-hidden="true" />
      </div>
      <div
        className="flex gap-2 p-2 border-t"
        style={{ borderColor: "var(--color-border)" }}
      >
        <input
          aria-label="Message to partner"
          aria-disabled={inputDisabled}
          disabled={inputDisabled}
          placeholder={
            playerDead
              ? ""
              : partnerThinking
                ? "Partner is thinking..."
                : "Reply to your partner..."
          }
          maxLength={MAX_CHARS}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={handleKeyDown}
          className="flex-1 px-3 py-2 rounded-md text-sm outline-none focus-visible:ring-2"
          style={{
            background: "var(--color-surface)",
            border: "1px solid var(--color-border)",
            color: "var(--color-text)",
            outlineColor: "var(--color-accent)",
          }}
          // playerSlot is read implicitly by the orchestrator from the
          // user_id on the WS conn; no need to send it on the frame.
          data-player-slot={playerSlot ?? ""}
        />
      </div>
    </div>
  );
}
