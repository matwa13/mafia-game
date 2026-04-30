import { type DependencyList, type RefObject, useEffect, useLayoutEffect, useRef, useState } from "react";

/**
 * Sticky-to-bottom scroll for chat-style lists. Auto-scrolls to the bottom
 * sentinel when `deps` change ONLY if the sentinel is currently visible (or
 * within ~100px of the visible area). Avoids the onScroll-during-programmatic-
 * scroll race that previously broke ChatTranscript: IntersectionObserver only
 * fires when intersection actually changes, so programmatic scrollIntoView
 * cannot accidentally flip the stuck flag off.
 *
 * Usage:
 *   const { scrollContainerRef, sentinelRef, stuckToBottom, scrollToBottom } =
 *     useStickyScroll(deps);
 *   // <div ref={scrollContainerRef} className="overflow-y-auto ...">
 *   //   ...messages...
 *   //   <div ref={sentinelRef} aria-hidden="true" />
 *   // </div>
 */
export function useStickyScroll(deps: DependencyList): {
  scrollContainerRef: RefObject<HTMLDivElement | null>;
  sentinelRef: RefObject<HTMLDivElement | null>;
  stuckToBottom: boolean;
  scrollToBottom: () => void;
} {
  const scrollContainerRef = useRef<HTMLDivElement | null>(null);
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  const [stuckToBottom, setStuckToBottom] = useState(true);

  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;
    const obs = new IntersectionObserver(
      ([entry]) => setStuckToBottom(entry.isIntersecting),
      { root: scrollContainerRef.current, rootMargin: "100px 0px 0px 0px", threshold: 0 },
    );
    obs.observe(sentinel);
    return () => obs.disconnect();
  }, []);

  useLayoutEffect(
    () => {
      if (stuckToBottom) {
        sentinelRef.current?.scrollIntoView({ behavior: "auto", block: "end" });
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [...deps, stuckToBottom],
  );

  const scrollToBottom = () => {
    sentinelRef.current?.scrollIntoView({ behavior: "auto", block: "end" });
  };

  return { scrollContainerRef, sentinelRef, stuckToBottom, scrollToBottom };
}
