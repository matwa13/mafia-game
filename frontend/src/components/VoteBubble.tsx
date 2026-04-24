import { clsx } from "clsx";

interface VoteBubbleProps {
  voterName: string;
  personaColor?: string;
  thinking?: boolean;
  targetName?: string;
  reasoning?: string;
}

export function VoteBubble({
  voterName,
  personaColor,
  thinking,
  targetName,
  reasoning,
}: VoteBubbleProps) {
  const color = personaColor ?? "var(--color-text-muted)";

  return (
    <div
      className={clsx(
        "rounded-md p-3 shadow-sm max-w-[560px] w-full",
        "animate-[bubbleEnter_180ms_ease-out]"
      )}
      style={{
        background: "var(--color-surface)",
        boxShadow: "var(--shadow-1)",
      }}
    >
      <div className="flex items-center gap-2 mb-1">
        <span
          className="text-base font-semibold"
          style={{
            borderBottom: `2px solid ${color}`,
            paddingBottom: 1,
          }}
        >
          {voterName}
        </span>
      </div>

      {thinking ? (
        <p
          className="leading-relaxed text-base italic"
          style={{ color: "var(--color-text-muted)" }}
          aria-label={`${voterName} is thinking`}
        >
          Thinking
          <span className="animate-[blink_1.2s_step-end_infinite]">.</span>
          <span className="animate-[blink_1.2s_step-end_infinite_0.2s]">.</span>
          <span className="animate-[blink_1.2s_step-end_infinite_0.4s]">.</span>
        </p>
      ) : (
        <>
          <div
            className="text-sm mb-2"
            style={{ color: "var(--color-text-muted)" }}
          >
            voting for{" "}
            <span
              className="font-semibold"
              style={{ color: "var(--color-text)" }}
            >
              {targetName ?? "—"}
            </span>
          </div>
          {reasoning && (
            <p
              className="leading-relaxed text-base"
              style={{ color: "var(--color-text)" }}
            >
              {reasoning}
            </p>
          )}
        </>
      )}
    </div>
  );
}
