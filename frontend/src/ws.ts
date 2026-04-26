import { useEffect, useRef } from "react";

export type FrameHandler = (topic: string, data: unknown) => void;

export function useGameSocket(onFrame: FrameHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const onFrameRef = useRef(onFrame);
  useEffect(() => { onFrameRef.current = onFrame; }, [onFrame]);

  useEffect(() => {
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
      console.log("[ws] open");
      // D-SD-03 / D-DP-01: dev_plugin only registers connections when it
      // receives an inbound dev_* command. Without this ping the plugin
      // never knows the SPA is connected, so dev_status never bootstraps,
      // game.devMode stays false, and the Setup-screen seed input never
      // renders. Empty payload — dev_plugin treats unknown dev_* commands
      // as no-ops and only uses the conn_pid for registration.
      ws.send(JSON.stringify({ type: "dev_hello", data: {} }));
    };
    ws.onclose = () => console.log("[ws] close");
    ws.onerror = (e) => console.warn("[ws] error", e);
    return () => { ws.close(); wsRef.current = null; };
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
