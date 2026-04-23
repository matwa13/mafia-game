import { useRef, useState } from "react";
import { useStore } from "../store";
import { Button } from "./primitives/Button";

const MAX_CHARS = 500;

export function InterjectionInput() {
  const chatLocked = useStore((s) => s.game.chatLocked);
  const phase = useStore((s) => s.game.phase);
  const round = useStore((s) => s.game.round);
  const [text, setText] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Input is only active during day discussion. Night / vote / reveal / ended
  // all suppress sending. This prevents player.chat messages from queuing in
  // the orchestrator's inbox while the orchestrator isn't in the day-
  // discussion loop — which otherwise leak into day 1 as the first bubble.
  const canSend = phase === "day" && !chatLocked;
  const placeholder = canSend
    ? "Say something..."
    : phase === "night"
      ? "Night — discussion closed."
      : chatLocked
        ? "Discussion is locked."
        : "Waiting...";

  function handleSend() {
    const trimmed = text.trim().slice(0, MAX_CHARS);
    if (!trimmed || !canSend) return;
    useStore.getState().send("game_chat_send", { text: trimmed, round });
    setText("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  }

  function handleInput(e: React.ChangeEvent<HTMLTextAreaElement>) {
    setText(e.target.value);
    // auto-grow up to 4 lines (~120px)
    const el = e.target;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 120)}px`;
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
      <textarea
        ref={textareaRef}
        aria-label="Chat input"
        disabled={!canSend}
        value={text}
        onChange={handleInput}
        onKeyDown={handleKeyDown}
        placeholder={placeholder}
        rows={1}
        className="flex-1 rounded-md px-3 py-2 text-base resize-none outline-none focus-visible:ring-2"
        style={{
          background: "var(--color-surface-raised)",
          color: "var(--color-text)",
          border: "1px solid var(--color-border)",
          minHeight: 40,
          maxHeight: 120,
          overflow: "hidden",
          outlineColor: "var(--color-accent)",
        }}
        maxLength={MAX_CHARS}
      />
      <Button
        variant="primary"
        size="md"
        disabled={!canSend || !text.trim()}
        onClick={handleSend}
        aria-label="Send message"
      >
        Send
      </Button>
    </div>
  );
}
