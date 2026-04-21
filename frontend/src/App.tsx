import { useEffect, useState } from "react";

type EchoResult = "pending" | "pong" | "error";

export default function App() {
  const [echo, setEcho] = useState<EchoResult>("pending");

  useEffect(() => {
    const url = `ws://${window.location.host}/ws`;
    const ws = new WebSocket(url);
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "echo_ping", payload: { ts: Date.now() } }));
    };
    ws.onmessage = (ev) => {
      try {
        const frame = JSON.parse(ev.data);
        if (frame && frame.type === "echo_pong") {
          setEcho("pong");
          console.log("[echo_pong]", frame.payload);
        }
      } catch {
        setEcho("error");
      }
    };
    ws.onerror = () => setEcho("error");
    return () => ws.close();
  }, []);

  return (
    <main style={{ fontFamily: "system-ui, sans-serif", padding: 24 }}>
      <h1>Mafia MVP — Phase 0 OK</h1>
      <p>echo status: <code>{echo}</code></p>
    </main>
  );
}
