import { useMemo } from "react";
import { useStore } from "../store";
import { useStickyScroll } from "../hooks/useStickyScroll";
import { ChatBubble } from "./ChatBubble";
import { MafiaChatBubble } from "./MafiaChatBubble";
import { SystemMessage } from "./SystemMessage";
import type { ChatMessage } from "../types";

interface ChatTranscriptProps {
  /**
   * Phase 4 — when true (or when phase === 'ended'), merge `sideChat.messages`
   * into the render set so the end-game scrollback shows mafia_chat bubbles
   * in seq order alongside public chat. Villager-humans never received any
   * mafia_chat events, so their merged set degenerates to public chat only
   * (D-EG-01 / T-04-22).
   */
  showMafiaChat?: boolean;
}

export function ChatTranscript({ showMafiaChat = false }: ChatTranscriptProps = {}) {
  const messages = useStore((s) => s.chat.messages);
  const typing = useStore((s) => s.chat.typing);
  const roster = useStore((s) => s.game.roster);
  const playerSlot = useStore((s) => s.game.playerSlot);
  const phase = useStore((s) => s.game.phase);
  const sideChatMessages = useStore((s) => s.sideChat.messages);
  const shouldRenderMafiaChat = showMafiaChat || phase === "ended";

  // Unified render list: committed messages + live "is typing..." bubbles,
  // both sorted by (round, seq). Orchestrator reserves a seq for each NPC
  // turn at the moment the turn starts and stamps it on the typing.started
  // event, so the typing bubble renders at the NPC's eventual committed
  // slot — no visual jump when the message finally lands.
  //
  // A user interjection during an NPC turn commits at a higher seq than the
  // in-flight NPC, so the typing bubble stays above the user's interjection
  // and is replaced in-place when the chat.line arrives.
  //
  // Defensive orphan-typing guard: if a committed message already exists for
  // (round, slot, seq), or for (round, slot) + kind "npc" with seq >= the
  // typing entry's seq, skip the typing entry at render time. Tracks max
  // committed seq per (round, slot) so the second pass of the day's two-pass
  // round-robin (msg_index=2 follow-up) still shows a typing bubble after the
  // msg_index=1 opener already committed at a lower seq for the same slot.
  type RenderItem =
    | { kind: "committed"; round: number; seq?: number; msg: ChatMessage; id: string }
    | { kind: "typing"; round: number; seq: number; typingKey: string; fromSlot: number };

  const renderItems = useMemo<RenderItem[]>(() => {
    const committedKeys = new Set<string>();
    const committedSlotRoundMaxSeq = new Map<string, number>();
    messages.forEach((m) => {
      if (m.seq != null) committedKeys.add(`${m.round}:${m.fromSlot}:${m.seq}`);
      if (m.kind === "npc" && m.seq != null) {
        const key = `${m.round}:${m.fromSlot}`;
        const cur = committedSlotRoundMaxSeq.get(key);
        if (cur == null || m.seq > cur) committedSlotRoundMaxSeq.set(key, m.seq);
      }
    });

    const items: RenderItem[] = [];
    messages.forEach((msg, i) => {
      items.push({
        kind: "committed",
        round: msg.round,
        seq: msg.seq,
        msg,
        id: `m-${i}-${msg.seq ?? "x"}`,
      });
    });

    // Phase 4 — merge mafia_chat into the render set when end-game scrollback
    // is enabled. Sort by (round, seq) downstream so mafia_chat interleaves
    // with public chat in the order it was generated.
    if (shouldRenderMafiaChat) {
      sideChatMessages.forEach((sm, i) => {
        const adapted: ChatMessage = {
          seq: sm.seq,
          round: sm.round,
          fromSlot: sm.fromSlot,
          fromName: sm.fromName,
          text: sm.text,
          kind: "mafia_chat",
        };
        items.push({
          kind: "committed",
          round: sm.round,
          seq: sm.seq,
          msg: adapted,
          id: `mc-${i}-${sm.seq}`,
        });
      });
    }

    Object.entries(typing).forEach(([typingKey, entry]) => {
      const exactKey = `${entry.round}:${entry.fromSlot}:${entry.seq}`;
      if (committedKeys.has(exactKey)) return;
      const slotRoundKey = `${entry.round}:${entry.fromSlot}`;
      const maxCommittedSeq = committedSlotRoundMaxSeq.get(slotRoundKey);
      if (maxCommittedSeq != null && entry.seq <= maxCommittedSeq) return;
      items.push({
        kind: "typing",
        round: entry.round,
        seq: entry.seq,
        typingKey,
        fromSlot: entry.fromSlot,
      });
    });
    items.sort((a, b) => {
      if (a.round !== b.round) return a.round - b.round;
      if (a.seq != null && b.seq != null) return a.seq - b.seq;
      return 0;
    });
    return items;
  }, [messages, typing, sideChatMessages, shouldRenderMafiaChat]);

  // Sticky-to-bottom auto-scroll. See useStickyScroll for the
  // IntersectionObserver-based race-free implementation that supersedes the
  // previously-reverted onScroll arithmetic attempt.
  const { scrollContainerRef, sentinelRef } = useStickyScroll([renderItems]);

  return (
    <div
      ref={scrollContainerRef}
      role="log"
      aria-live="polite"
      aria-atomic="false"
      className="flex-1 min-h-0 overflow-y-auto flex flex-col items-center gap-4 p-4"
      style={{ maxWidth: 720, margin: "0 auto", width: "100%" }}
    >
      {renderItems.map((item) => {
        if (item.kind === "committed") {
          const msg = item.msg;
          const entry = roster[msg.fromSlot];
          const isHuman = msg.fromSlot === playerSlot || msg.kind === "human";
          const isDead = entry ? !entry.alive : false;

          if (msg.kind === "system") {
            return <SystemMessage key={item.id} text={msg.text} />;
          }

          if (msg.kind === "mafia_chat") {
            // End-game scrollback path — render mafia_chat with wine bg.
            return (
              <MafiaChatBubble
                key={item.id}
                message={{
                  seq: msg.seq ?? 0,
                  round: msg.round,
                  fromSlot: msg.fromSlot,
                  fromName: msg.fromName,
                  text: msg.text,
                }}
              />
            );
          }

          return (
            <ChatBubble
              key={item.id}
              speaker={{
                name: msg.fromName,
                personaColor: entry?.personaColor,
                isHuman,
                isDead,
              }}
              content={msg.text}
              isInterjection={msg.kind === "human" && msg.fromSlot === playerSlot}
              isLastWords={msg.kind === "last_words"}
            />
          );
        }

        // "is typing..." bubble — renders at the NPC's reserved seq slot.
        const rosterEntry = roster[item.fromSlot];
        const isHuman = item.fromSlot === playerSlot;
        return (
          <ChatBubble
            key={`typing-${item.typingKey}`}
            speaker={{
              name: rosterEntry?.name ?? String(item.fromSlot),
              personaColor: rosterEntry?.personaColor,
              isHuman,
            }}
            content=""
            isTyping
          />
        );
      })}
      {/* Bottom sentinel — scrollIntoView target for auto-scroll. */}
      <div ref={sentinelRef} aria-hidden="true" />
    </div>
  );
}
