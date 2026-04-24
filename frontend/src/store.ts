import { create } from "zustand";
import type { GameState, ChatMessage, VoteState } from "./types";

interface TypingEntry {
  fromSlot: number;
  round: number;
  // Reserved seq from the orchestrator. Used by ChatTranscript to position
  // the typing bubble at the NPC's eventual committed slot.
  seq: number;
}

interface ChatSlice {
  messages: ChatMessage[];
  typing: Record<string, TypingEntry>;
}

interface StoreState {
  game: GameState;
  chat: ChatSlice;
  vote: VoteState;
  send: (type: string, data: unknown) => void;
  setSend: (fn: (type: string, data: unknown) => void) => void;
  applyFrame: (topic: string, data: unknown) => void;
}

const initialGame: GameState = {
  phase: null,
  round: 0,
  roster: {},
  playerSlot: null,
  playerRole: null,
  partnerName: null,
  chatLocked: false,
  lastEliminated: null,
  winner: null,
  gameId: null,
  discussionReady: false,
  awaitingNextDay: false,
};

const initialVote: VoteState = {
  revealed: false,
  tally: {},
  perVoter: [],
  tied: false,
  playerVote: null,
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function asRecord(v: unknown): Record<string, any> {
  return (v && typeof v === "object" ? v : {}) as Record<string, any>;
}

export const useStore = create<StoreState>((set, get) => ({
  game: initialGame,
  chat: { messages: [], typing: {} },
  vote: initialVote,
  send: (_type: string, _data: unknown) => {
    console.warn("[store] send called before ws hook set it");
  },
  setSend: (fn) => set({ send: fn }),

  applyFrame: (topic: string, rawData: unknown) => {
    const data = asRecord(rawData);

    if (topic === "game_state_changed") {
      const roster: GameState["roster"] = {};
      const rawRoster = asRecord(data.roster);
      for (const [k, v] of Object.entries(rawRoster)) {
        const slot = parseInt(k, 10);
        const rv = asRecord(v);
        roster[slot] = {
          name: String(rv.name ?? ""),
          alive: Boolean(rv.alive),
          role: rv.role != null ? String(rv.role) : undefined,
          archetypeId: rv.archetype_id != null ? String(rv.archetype_id) : undefined,
          archetypeLabel: rv.archetype_label != null ? String(rv.archetype_label) : undefined,
          voiceBlurb: rv.voice_blurb != null ? String(rv.voice_blurb) : undefined,
          personaColor: rv.persona_color != null ? String(rv.persona_color) : undefined,
        };
      }

      const nextRound = data.round != null ? Number(data.round) : undefined;

      set((s) => {
        // On a new round, clear the user-gated readiness flags so last
        // round's button state doesn't bleed into this one.
        const roundChanged = nextRound != null && nextRound !== s.game.round;
        return {
          game: {
            ...s.game,
            phase: data.phase ?? s.game.phase,
            round: nextRound ?? s.game.round,
            roster,
            playerSlot: data.player_slot != null ? Number(data.player_slot) : s.game.playerSlot,
            playerRole: data.player_role != null ? String(data.player_role) : s.game.playerRole,
            partnerName: data.partner_name != null ? String(data.partner_name) : s.game.partnerName,
            chatLocked: Boolean(data.chat_locked),
            lastEliminated: data.last_eliminated != null
              ? asRecord(data.last_eliminated) as GameState["lastEliminated"]
              : s.game.lastEliminated,
            winner: data.winner != null ? data.winner as "mafia" | "villager" : s.game.winner,
            gameId: data.game_id != null ? String(data.game_id) : s.game.gameId,
            discussionReady: roundChanged ? false : s.game.discussionReady,
            awaitingNextDay: roundChanged ? false : s.game.awaitingNextDay,
          },
          // Reset vote state on new game state
          vote: data.phase === "vote" ? { ...initialVote } : s.vote,
        };
      });
      return;
    }

    if (topic === "game_discussion_ready") {
      set((s) => ({ game: { ...s.game, discussionReady: true } }));
      return;
    }

    if (topic === "game_vote_complete") {
      set((s) => ({ game: { ...s.game, awaitingNextDay: true } }));
      return;
    }

    if (topic === "game_typing_started") {
      const round = Number(data.round);
      const fromSlot = Number(data.from_slot);
      const seq = Number(data.seq);
      if (!Number.isFinite(round) || !Number.isFinite(fromSlot) || !Number.isFinite(seq)) return;
      const key = `${round}:${fromSlot}:${seq}`;
      set((s) => ({
        chat: {
          ...s.chat,
          typing: { ...s.chat.typing, [key]: { fromSlot, round, seq } },
        },
      }));
      return;
    }

    if (topic === "game_typing_ended") {
      const round = Number(data.round);
      const fromSlot = Number(data.from_slot);
      const seq = data.seq != null ? Number(data.seq) : undefined;
      set((s) => {
        const newTyping = { ...s.chat.typing };
        if (seq != null) {
          delete newTyping[`${round}:${fromSlot}:${seq}`];
        } else {
          // Defensive: if seq missing, clear any typing for this (round, slot).
          const prefix = `${round}:${fromSlot}:`;
          for (const k of Object.keys(newTyping)) {
            if (k.startsWith(prefix)) delete newTyping[k];
          }
        }
        return { chat: { ...s.chat, typing: newTyping } };
      });
      return;
    }

    if (topic === "game_chat_line") {
      const round = Number(data.round);
      const fromSlot = Number(data.from_slot);
      const seq = data.seq != null ? Number(data.seq) : undefined;
      const roster = get().game.roster;
      const fromName = roster[fromSlot]?.name ?? String(data.from_slot ?? fromSlot);
      const msg: ChatMessage = {
        seq,
        round,
        fromSlot,
        fromName,
        text: String(data.text ?? ""),
        kind: (data.kind as ChatMessage["kind"]) ?? "npc",
      };
      // Clear any typing bubble for this (round, slot) — commit implicitly
      // ends typing. Prefix-match is defensive in case seq mismatched.
      const prefix = `${round}:${fromSlot}:`;
      set((s) => {
        const newTyping = { ...s.chat.typing };
        for (const k of Object.keys(newTyping)) {
          if (k.startsWith(prefix)) delete newTyping[k];
        }
        return {
          chat: {
            messages: [...s.chat.messages, msg],
            typing: newTyping,
          },
        };
      });
      return;
    }

    if (topic === "game_chat_locked") {
      set((s) => ({
        game: { ...s.game, chatLocked: true, phase: "vote" },
      }));
      return;
    }

    if (topic === "game_eliminated") {
      const victimSlot = Number(data.victim_slot);
      set((s) => {
        const newRoster = { ...s.game.roster };
        if (newRoster[victimSlot]) {
          newRoster[victimSlot] = {
            ...newRoster[victimSlot],
            alive: false,
            role: data.revealed_role != null ? String(data.revealed_role) : newRoster[victimSlot].role,
          };
        }
        return {
          game: {
            ...s.game,
            lastEliminated: {
              slot: victimSlot,
              name: newRoster[victimSlot]?.name ?? String(victimSlot),
              role: String(data.revealed_role ?? ""),
              cause: String(data.cause ?? ""),
            },
            roster: newRoster,
          },
        };
      });
      return;
    }

    if (topic === "game_vote_cast_received") {
      const fromSlot = Number(data.from_slot);
      if (!Number.isFinite(fromSlot)) return;
      const entry = {
        from_slot: fromSlot,
        from_name: String(data.from_name ?? ""),
        vote_for_slot: data.vote_for_slot != null ? Number(data.vote_for_slot) : null,
        reasoning: String(data.reasoning ?? ""),
      };
      set((s) => {
        if (s.vote.perVoter.some((v) => v.from_slot === fromSlot)) return s;
        return { vote: { ...s.vote, perVoter: [...s.vote.perVoter, entry] } };
      });
      return;
    }

    if (topic === "game_votes_revealed") {
      const finalPerVoter = Array.isArray(data.per_voter) ? data.per_voter : [];
      set((s) => ({
        vote: {
          ...s.vote,
          revealed: true,
          tally: asRecord(data.tally) as Record<number, number>,
          // Prefer the authoritative `per_voter` payload; the incremental
          // stream populated it earlier but this is the source of truth.
          perVoter: finalPerVoter.length > 0 ? finalPerVoter : s.vote.perVoter,
          tied: Boolean(data.tied),
        },
      }));
      return;
    }

    if (topic === "game_vote_tied") {
      set((s) => ({
        vote: { ...s.vote, tied: true },
      }));
      return;
    }

    if (topic === "game_game_ended") {
      set((s) => ({
        game: {
          ...s.game,
          phase: "ended",
          winner: data.winner as "mafia" | "villager" ?? s.game.winner,
        },
      }));
      return;
    }

    if (topic === "game_error") {
      const errorText = data.error != null
        ? String(data.error)
        : `Error: ${String(data.code ?? "unknown")}`;
      const msg: ChatMessage = {
        round: get().game.round,
        fromSlot: 0,
        fromName: "System",
        text: errorText,
        kind: "system",
      };
      set((s) => ({
        chat: { ...s.chat, messages: [...s.chat.messages, msg] },
      }));
      return;
    }

    // game_npc_skipped — optional diagnostic, no UI in Phase 3
  },
}));
