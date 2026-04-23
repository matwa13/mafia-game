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
    ws.onopen = () => console.log("[ws] open");
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
