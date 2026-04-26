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
  // Phase 5 — dev-mode flag + last seed (D-SD-03).
  devMode: boolean;
  seed: number | null;
}

/** Phase 5 D-SD-03: bootstrap dev-mode flag from relay plugin on WS connect. */
export interface DevModeChangedFrame {
  type: "dev_mode_changed";
  enabled: boolean;
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

// Phase 5 D-DP-06 — per-NPC dev telemetry snapshot card shape.
export interface DevNpcSnapshot {
  slot: number;
  name?: string;
  archetype?: string;
  alive: boolean;
  role: "mafia" | "villager";
  suspicion: Record<number, { score: number; reasons?: string[] }>;
  stable_sha?: string;
  dynamic_tail?: string;
  last_llm_error?: { type: string; message: string; attempt?: number } | null;
  last_vote?: { round: number; target_slot: number; justification: string } | null;
  last_pick?: { round: number; target_slot: number; reasoning: string; confidence?: string } | null;
  unavailable?: boolean;
}

// Phase 5 D-DP-10 — scope-tagged event entry for the dev event tail.
export interface DevEvent {
  scope: "public" | "mafia" | "system" | "dev";
  kind: string;
  path?: string;
  ts: number;
  summary?: string;
}

// Phase 5 D-DP-01 — dev_status frame sent on WS join from dev_plugin in dev mode.
export interface DevStatusFrame {
  type: "dev_status";
  enabled: boolean;
}

// Phase 5 D-DP-05 — dev_snapshot frame sent on every phase transition.
export interface DevSnapshotFrame {
  type: "dev_snapshot";
  game_id: string;
  seed: number;
  round: number;
  phase: "intro" | "night" | "day" | "vote" | "reveal" | "ended";
  mafia_slots: [number, number];
  roster: Record<number, DevNpcSnapshot>;
  event_tail: DevEvent[];
}
