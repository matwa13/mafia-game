import { ChatBubble } from "./ChatBubble";
import { useStore } from "../store";
import type { SideChatMessage } from "../types";

/**
 * Wine-themed wrapper around ChatBubble for mafia_chat lines.
 * Looks up the speaker's persona color from the roster so the partner-NPC's
 * speaker-name underline matches its archetype (UI-SPEC §9).
 */
export function MafiaChatBubble({ message }: { message: SideChatMessage }) {
  const playerSlot = useStore((s) => s.game.playerSlot);
  const roster = useStore((s) => s.game.roster);
  const isHuman = message.fromSlot === playerSlot;
  const entry = roster[message.fromSlot];

  return (
    <ChatBubble
      speaker={{
        name: message.fromName,
        personaColor: entry?.personaColor,
        isHuman,
        isDead: entry ? !entry.alive : false,
      }}
      content={message.text}
      isMafiaChat
    />
  );
}
