import { useLayoutEffect, useRef } from "react";
import type { DevEvent } from "../types";

interface Props {
  events: DevEvent[];
}

const scopeStyle: Record<string, React.CSSProperties> = {
  public: { background: "var(--color-surface-raised)", color: "var(--color-text-muted)" },
  mafia: { background: "var(--color-mafia-chat-surface)", color: "var(--color-role-mafia)" },
  system: { background: "var(--color-surface)", color: "var(--color-text-muted)" },
  dev: { background: "var(--color-surface-raised)", color: "var(--color-accent)" },
};

export function DevEventTail({ events }: Props) {
  const endRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "instant" });
  }, [events.length]);

  return (
    <div style={{ borderTop: "1px solid var(--color-border)" }}>
      <p
        className="text-xs font-semibold uppercase px-3 pt-2"
        style={{ color: "var(--color-text-muted)" }}
      >
        EVENT LOG (last 20)
      </p>
      <div
        role="log"
        aria-live="polite"
        aria-atomic="false"
        style={{ maxHeight: 200, overflowY: "auto" }}
        className="px-3 pb-2"
      >
        {events.length === 0 ? (
          <p
            className="text-xs italic"
            style={{ color: "var(--color-text-muted)" }}
          >
            (no events yet)
          </p>
        ) : (
          events.map((ev, i) => (
            <div key={i} className="flex items-baseline gap-1 text-xs py-0.5">
              <span
                className="px-1 rounded flex-shrink-0"
                style={scopeStyle[ev.scope] ?? scopeStyle.system}
              >
                {ev.scope}
              </span>
              <span
                className="truncate"
                style={{ color: "var(--color-text-muted)", maxWidth: 200 }}
              >
                {ev.kind}{ev.path ? ` ${ev.path}` : ""}
              </span>
              {ev.summary && (
                <span className="truncate flex-1" style={{ color: "var(--color-text-muted)" }}>
                  {ev.summary}
                </span>
              )}
            </div>
          ))
        )}
        <div ref={endRef} />
      </div>
    </div>
  );
}
