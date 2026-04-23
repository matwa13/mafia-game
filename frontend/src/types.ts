export type GamePhase =
  | "starting"
  | "night"
  | "day"
  | "vote"
  | "reveal"
  | "ended";

export interface RosterEntry {
  name: string;
  alive: boolean;
  role?: string;
  archetypeId?: string;
  personaColor?: string;
}

export interface LastElimination {
  slot: number;
  name: string;
  role: string;
  cause: string;
}

export interface GameState {
  phase: GamePhase | null;
  round: number;
  roster: Record<number, RosterEntry>;
  playerSlot: number | null;
  playerRole: string | null;
  partnerName: string | null;
  chatLocked: boolean;
  lastEliminated: LastElimination | null;
  winner: "mafia" | "villager" | null;
  gameId: string | null;
}

export interface ChatMessage {
  seq?: number;
  round: number;
  fromSlot: number;
  fromName: string;
  text: string;
  kind: "npc" | "human" | "last_words" | "system";
}

export interface VotePerVoter {
  from_slot: number;
  from_name: string;
  vote_for_slot: number | null;
  reasoning: string;
}

export interface VoteState {
  revealed: boolean;
  tally: Record<number, number>;
  perVoter: VotePerVoter[];
  tied: boolean;
  playerVote: number | null;
}

export interface ClientFrame {
  type: string;
  data: unknown;
}

export interface ServerFrame {
  topic: string;
  data: unknown;
}
