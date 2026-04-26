// Phase 5 D-RH-06 — translucent "Reconnecting…" overlay shown while the
// WS is closed mid-game. Flips on in ws.onclose (when phase is non-null +
// not "ended"); flips off on the first post-reconnect game_state_changed
// for the active game_id (see store.ts game_state_changed handler).
//
// UI-SPEC §6: pointer-events-none so the underlying game stays visible (dimmed)
// but doesn't capture clicks; instant mount/unmount, no animation.
import { useStore } from "../store";

export function ReconnectingOverlay() {
  const rehydrating = useStore((s) => s.game.rehydrating);
  if (!rehydrating) return null;
  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed inset-0 z-40 flex items-center justify-center pointer-events-none"
      style={{ background: "rgba(0,0,0,0.7)" }}
    >
      <p
        className="text-sm"
        style={{ color: "var(--color-text-muted)" }}
      >
        Reconnecting&hellip;
      </p>
    </div>
  );
}
