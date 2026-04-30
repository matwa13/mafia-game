import { useState } from "react";
import { Button } from "./primitives/Button";

interface LastWordsCardProps {
  victimName: string;
  text: string;
  onContinue?: () => void;
}

export function LastWordsCard({ victimName, text, onContinue }: LastWordsCardProps) {
  const [dismissed, setDismissed] = useState(false);

  if (dismissed) return null;

  function handleContinue() {
    setDismissed(true);
    onContinue?.();
  }

  return (
    <div
      className="rounded-md p-6 mx-auto my-4 flex flex-col gap-4"
      style={{
        maxWidth: 560,
        background: "var(--color-surface)",
        border: "1px solid var(--color-border)",
        boxShadow: "var(--shadow-2)",
        animationName: "lastWordsEnter",
        animationDuration: "240ms",
        animationTimingFunction: "ease-out",
        animationFillMode: "both",
      }}
    >
      {/* Speaker */}
      <div className="flex items-center gap-2">
        <span
          className="w-3 h-3 rounded-full"
          style={{ background: "var(--color-text-muted)" }}
        />
        <span className="text-lg font-semibold">{victimName}</span>
      </div>

      {/* Label */}
      <p
        className="text-xs tracking-widest uppercase"
        style={{ color: "var(--color-text-muted)" }}
      >
        Last words:
      </p>

      {/* Quote */}
      <p
        className="text-2xl font-semibold tracking-tight"
        style={{ color: "var(--color-text)" }}
      >
        "{text}"
      </p>

      {/* Continue */}
      <div className="flex justify-end">
        <Button variant="secondary" size="md" onClick={handleContinue}>
          Continue
        </Button>
      </div>
    </div>
  );
}
