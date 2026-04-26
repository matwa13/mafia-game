import { useEffect, useRef } from "react";
import { useStore } from "./store";

export type FrameHandler = (topic: string, data: unknown) => void;

export function useGameSocket(onFrame: FrameHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const onFrameRef = useRef(onFrame);
  useEffect(() => { onFrameRef.current = onFrame; }, [onFrame]);

  useEffect(() => {
    let cancelled = false;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let attempt = 0;

    const connect = () => {
      if (cancelled) return;
      const url = `ws://${window.location.host}/ws/`;
      const ws = new WebSocket(url);
      wsRef.current = ws;
      ws.onmessage = (ev) => {
        try {
          const frame = JSON.parse(ev.data);
          if (frame && typeof frame.topic === "string") {
            onFrameRef.current(frame.topic, frame.data);
          }
        } catch (e) {
          console.warn("[ws] parse failed", e);
        }
      };
      ws.onopen = () => {
        attempt = 0;
        console.log("[ws] open");
        // D-SD-03 / D-DP-01: dev_plugin only registers connections when it
        // receives an inbound dev_* command. Empty payload — the plugin
        // treats unknown dev_* commands as no-ops and uses conn_pid for
        // registration so dev_status can bootstrap.
        ws.send(JSON.stringify({ type: "dev_hello", data: {} }));
        // Phase 5: SPA-driven resume after wippy restart. If we have a
        // gameId in memory AND were mid-game when the socket closed, ask
        // the server to resume that game. game_plugin will respond with
        // game.resumed (orchestrator respawned with rehydrate=true) or
        // game_resume_failed (game ended/missing → store clears gameId).
        const s = useStore.getState();
        if (s.game.gameId != null && s.game.rehydrating) {
          ws.send(JSON.stringify({
            type: "game_resume",
            data: { game_id: s.game.gameId },
          }));
        }
      };
      ws.onclose = () => {
        console.log("[ws] close");
        // Phase 5 D-RH-06: if a game is in progress when the WS closes,
        // flip game.rehydrating so ReconnectingOverlay mounts. Cleared on
        // first post-reconnect game_state_changed (see store.ts).
        const s = useStore.getState();
        const phase = s.game.phase;
        if (phase != null && phase !== "ended" && s.game.gameId != null) {
          useStore.setState((st) => ({
            game: { ...st.game, rehydrating: true },
          }));
        }
        if (cancelled) return;
        // Backoff: 1s for the first 5 attempts, then 5s. The ReconnectingOverlay
        // stays visible across all retries until the resume handshake completes.
        attempt += 1;
        const delay = attempt <= 5 ? 1000 : 5000;
        reconnectTimer = setTimeout(connect, delay);
      };
      ws.onerror = (e) => console.warn("[ws] error", e);
    };

    connect();
    return () => {
      cancelled = true;
      if (reconnectTimer != null) clearTimeout(reconnectTimer);
      wsRef.current?.close();
      wsRef.current = null;
    };
  }, []);

  return {
    send: (type: string, data: unknown) => {
      const ws = wsRef.current;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type, data }));
      } else {
        console.warn("[ws] send dropped — not open", { type });
      }
    },
  };
}
