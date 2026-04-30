import { clsx } from "clsx";

interface Speaker {
  name: string;
  personaColor?: string;
  isHuman?: boolean;
  isDead?: boolean;
}

interface ChatBubbleProps {
  speaker: Speaker;
  content: string;
  isTyping?: boolean;
  isInterjection?: boolean;
  isLastWords?: boolean;
  /**
   * Phase 4 — when true, swaps the bubble background to the wine
   * `--color-mafia-chat-surface` token. Used by `MafiaChatBubble` and the
   * end-game scrollback (ChatTranscript with `showMafiaChat=true`).
   */
  isMafiaChat?: boolean;
  timestamp?: number;
}

export function ChatBubble({
  speaker,
  content,
  isTyping,
  isInterjection,
  isLastWords,
  isMafiaChat,
}: ChatBubbleProps) {
  const { name, personaColor, isHuman, isDead } = speaker;
  const color = isHuman ? "var(--color-accent)" : (personaColor ?? "var(--color-text-muted)");

  // Phase 4 — mafia_chat bubbles override the default surface with the
  // wine token. Human's mafia_chat keeps the existing left-accent border;
  // partner-NPC mafia_chat keeps the role-color underline on the speaker
  // name (no left border — same as a regular NPC bubble).
  const background = isMafiaChat
    ? "var(--color-mafia-chat-surface)"
    : isHuman
      ? "var(--color-surface-raised)"
      : "var(--color-surface)";

  return (
    <div
      className={clsx(
        "rounded-md p-3 shadow-sm max-w-[560px] w-full animate-[bubbleEnter_180ms_ease-out]",
        isLastWords && "border border-[color:var(--color-border)]"
      )}
      style={{
        background,
        borderLeft: isHuman ? "2px solid var(--color-accent)" : undefined,
        opacity: isDead ? 0.6 : 1,
        boxShadow: "var(--shadow-1)",
      }}
    >
      {/* Speaker row */}
      <div className="flex items-center gap-2 mb-1">
        <span
          className={clsx(
            "text-base font-semibold",
            isDead && "line-through"
          )}
          style={{
            textDecoration: isDead ? "line-through" : undefined,
            borderBottom: `2px solid ${color}`,
            paddingBottom: 1,
          }}
        >
          {name}
          {isInterjection && (
            <span className="ml-1 text-sm" style={{ color: "var(--color-text-muted)" }}>
              ⏵
            </span>
          )}
        </span>
      </div>

      {/* Last-words label */}
      {isLastWords && (
        <div
          className="text-xs tracking-widest uppercase mb-2"
          style={{ color: "var(--color-text-muted)" }}
        >
          Last words:
        </div>
      )}

      {/* Content */}
      {isTyping ? (
        <p
          className="leading-relaxed text-base italic"
          style={{ color: "var(--color-text-muted)" }}
          aria-label={`${name} is typing`}
        >
          is typing
          <span className="animate-[blink_1.2s_step-end_infinite]">.</span>
          <span className="animate-[blink_1.2s_step-end_infinite_0.2s]">.</span>
          <span className="animate-[blink_1.2s_step-end_infinite_0.4s]">.</span>
        </p>
      ) : (
        <p
          className={clsx(
            "leading-relaxed",
            isLastWords ? "text-2xl font-semibold tracking-tight" : "text-base"
          )}
          style={{ color: "var(--color-text)" }}
        >
          {content}
        </p>
      )}
    </div>
  );
}
