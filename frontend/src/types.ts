export type GamePhase =
  | "starting"
  | "intro"
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
  archetypeLabel?: string;
  voiceBlurb?: string;
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
  // User-gated phase transitions. The orchestrator no longer auto-advances;
  // these flags flip to `true` when the backend signals that the current
  // phase is ready to end, enabling the corresponding action button.
  discussionReady: boolean;  // set by day.discussion_ready; enables "End discussion"
  awaitingNextDay: boolean;  // set by day.vote_complete;   enables "Start next day"
  // Phase 4 — preserved across Start New Game; mirrors night.awaitingBeginDay
  // for convenience selectors that don't want to drill into the night slice.
  playerName?: string;
  awaitingBeginDay: boolean;
}

export interface ChatMessage {
  seq?: number;
  round: number;
  fromSlot: number;
  fromName: string;
  text: string;
  kind: "npc" | "human" | "last_words" | "system" | "mafia_chat";
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

/**
 * Phase 4 — Mafia side-chat slice.
 *
 * `messages` accumulates `kind="mafia_chat"` chat lines for the Mafia-human
 * channel. The Villager-human never receives mafia_chat events from the relay,
 * so their `messages` array stays empty and the end-game scrollback shows
 * only public chat — D-EG-01 / T-04-22.
 *
 * `partnerSuggestedSlot` mirrors the most recent partner suggestion so the
 * NightPicker can render the dashed-accent suggestion chip + badge.
 */
export interface SideChatMessage {
  seq: number;
  round: number;
  fromSlot: number;
  fromName: string;
  text: string;
  suggestedTargetSlot?: number;
}

export interface SideChatTypingEntry {
  fromSlot: number;
  round: number;
  seq: number;
}

export interface SideChatSlice {
  messages: SideChatMessage[];
  typing: Record<string, SideChatTypingEntry>;
  partnerSuggestedSlot: number | null;
}

/**
 * Phase 4 — Night slice for the Mafia-human kill-picker UI.
 *
 * `awaitingBeginDay` flips true when the orchestrator signals
 * `game_night_ready_for_day`; reset on every round-change frame so the
 * previous night's flag never bleeds into the current one (T-04-24).
 */
export interface NightSlice {
  awaitingBeginDay: boolean;
  pickedSlot: number | null;
  locked: boolean;
}

export interface ClientFrame {
  type: string;
  data: unknown;
}

export interface ServerFrame {
  topic: string;
  data: unknown;
}
