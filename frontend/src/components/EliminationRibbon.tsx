import { useEffect, useState } from "react";

interface EliminationRibbonProps {
  victimName: string;
}

export function EliminationRibbon({ victimName }: EliminationRibbonProps) {
  const [hiddenFor, setHiddenFor] = useState<string | null>(null);

  useEffect(() => {
    const timer = setTimeout(() => setHiddenFor(victimName), 6500);
    return () => clearTimeout(timer);
  }, [victimName]);

  if (hiddenFor === victimName) return null;

  return (
    <div
      role="alert"
      className="flex items-center justify-center w-full font-semibold text-2xl tracking-tight"
      style={{
        height: 64,
        background: "var(--color-danger)",
        color: "var(--color-text)",
        boxShadow: "var(--shadow-2)",
        animationName: "slideDownRibbon",
        animationDuration: "400ms",
        animationTimingFunction: "ease-out",
        animationFillMode: "both",
      }}
    >
      {victimName.toUpperCase()} WAS ELIMINATED.
    </div>
  );
}
