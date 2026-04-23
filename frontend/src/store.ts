import { create } from "zustand";
import type { GameState, ChatMessage, VoteState } from "./types";

interface StreamingEntry {
  fromSlot: number;
  round: number;
  text: string;
}

interface ChatSlice {
  messages: ChatMessage[];
  streaming: Record<string, StreamingEntry>;
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
  chat: { messages: [], streaming: {} },
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
          personaColor: rv.persona_color != null ? String(rv.persona_color) : undefined,
        };
      }

      set((s) => ({
        game: {
          ...s.game,
          phase: data.phase ?? s.game.phase,
          round: data.round != null ? Number(data.round) : s.game.round,
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
        },
        // Reset vote state on new game state
        vote: data.phase === "vote" ? { ...initialVote } : s.vote,
      }));
      return;
    }

    if (topic === "game_chat_chunk") {
      const round = Number(data.round);
      const fromSlot = Number(data.from_slot);
      const text = String(data.text ?? "");
      const key = `${round}:${fromSlot}`;
      set((s) => ({
        chat: {
          ...s.chat,
          streaming: {
            ...s.chat.streaming,
            [key]: {
              fromSlot,
              round,
              text: (s.chat.streaming[key]?.text ?? "") + text,
            },
          },
        },
      }));
      return;
    }

    if (topic === "game_chat_line") {
      const round = Number(data.round);
      const fromSlot = Number(data.from_slot);
      const key = `${round}:${fromSlot}`;
      const roster = get().game.roster;
      const fromName = roster[fromSlot]?.name ?? String(data.from_slot ?? fromSlot);
      const msg: ChatMessage = {
        seq: data.seq != null ? Number(data.seq) : undefined,
        round,
        fromSlot,
        fromName,
        text: String(data.text ?? ""),
        kind: (data.kind as ChatMessage["kind"]) ?? "npc",
      };
      set((s) => {
        const newStreaming = { ...s.chat.streaming };
        delete newStreaming[key];
        return {
          chat: {
            messages: [...s.chat.messages, msg],
            streaming: newStreaming,
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

    if (topic === "game_votes_revealed") {
      set((s) => ({
        vote: {
          ...s.vote,
          revealed: true,
          tally: asRecord(data.tally) as Record<number, number>,
          perVoter: Array.isArray(data.per_voter) ? data.per_voter : [],
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
