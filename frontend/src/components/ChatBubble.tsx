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
  isStreaming?: boolean;
  isInterjection?: boolean;
  isLastWords?: boolean;
  timestamp?: number;
}

export function ChatBubble({
  speaker,
  content,
  isStreaming,
  isInterjection,
  isLastWords,
}: ChatBubbleProps) {
  const { name, personaColor, isHuman, isDead } = speaker;
  const color = isHuman ? "var(--color-accent)" : (personaColor ?? "var(--color-text-muted)");

  return (
    <div
      className={clsx(
        "rounded-md p-3 shadow-sm max-w-[560px] w-full animate-[bubbleEnter_180ms_ease-out]",
        isLastWords && "border border-[color:var(--color-border)]"
      )}
      style={{
        background: isHuman
          ? "var(--color-surface-raised)"
          : "var(--color-surface)",
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
          {isHuman ? "You" : name}
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
      <p
        className={clsx(
          "leading-relaxed",
          isLastWords ? "text-2xl font-semibold tracking-tight" : "text-base"
        )}
        style={{ color: "var(--color-text)" }}
      >
        {content}
        {isStreaming && (
          <span
            className="animate-[blink_1s_step-end_infinite]"
            style={{ color: "var(--color-text-muted)" }}
          >
            ▊
          </span>
        )}
      </p>
    </div>
  );
}
