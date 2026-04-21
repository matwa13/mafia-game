# Single-Player Mafia MVP

## What This Is

A single-player adaptation of the social deduction game Mafia, where one human plays alongside five LLM-driven AI characters. The product's primary purpose is to serve as a non-trivial learning showcase for the **Wippy** application runtime — exercising its process model, agents framework, workflows, SQL storage, and websocket relay in a single coherent scenario. The secondary purpose is to be an actually playable, coherent game that the developer and teammates can run locally and enjoy.

## Core Value

**NPCs feel like distinct, stable characters genuinely playing Mafia** — bluffing when Mafia, deducing when Villagers, voting on real signal, remembering what happened. If the personas flatten into interchangeable chatbots, the product fails regardless of how clean the infrastructure is.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these. -->

- [ ] Six-participant game: 1 human + 5 AI NPCs, exactly 2 Mafia and 4 Villagers
- [ ] Random hidden role assignment at game start (human may be Mafia or Villager)
- [ ] Each NPC has a distinct name, personality, and stable communication style for the full game
- [ ] Hybrid NPC generation: names/archetypes from a curated pool, personality/voice LLM-generated on top
- [ ] Process-per-NPC architecture: each NPC is a supervised Wippy process holding its own persona and suspicion state
- [ ] Claude (Anthropic) powers NPC dialogue and voting via Wippy's `framework/llm`
- [ ] Game loop: Night → Day Discussion → Voting, repeated until a win condition
- [ ] Game opens at Night 1 — a kill happens before Day 1 discussion
- [ ] Night Phase: when human is Mafia, player picks the target; when human is Villager, resolves automatically
- [ ] Mafia coordination: when human is Mafia, a private side-chat with the Mafia partner NPC precedes the kill pick
- [ ] Day Discussion: shared chat, 60-second cap, sequential NPC turns (1–2 messages each), player may interject anytime
- [ ] Chat is locked when discussion ends; game transitions to voting
- [ ] Voting Phase: player votes manually (no timer), NPCs vote automatically using discussion + suspicion + role incentives
- [ ] Tie handling: no elimination on tie, proceed to next night
- [ ] Role is revealed on death (lynch or night kill) in the chat log
- [ ] Win conditions: Villagers win when all Mafia eliminated; Mafia win when Mafia >= Villagers
- [ ] End-of-game screen with full game log; "Start New Game" button spins up a fresh game (new personas, new roles)
- [ ] Game history persists in SQLite via Wippy's `storage/sql` — restart-safe, browsable after the fact
- [ ] React SPA frontend, communicating with Wippy backend over WebSocket (Wippy's websocket relay)
- [ ] Dev mode (first-class): fast timers, seeded RNG, side panel exposing each NPC's private suspicion state
- [ ] Player always knows: who's alive, current phase, discussion open/closed, who was eliminated, win/loss result

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Doctor / Detective / Sheriff / any special roles beyond Mafia/Villager — MVP focuses on the base two-team mechanic
- Multiplayer (multiple humans in one game) — single-player by design
- User accounts, auth, profiles — local-only, just the developer and teammates
- Hosted/public deployment — runs locally via `wippy run`
- Matchmaking, leaderboards, progression, monetization — outside MVP and outside project intent
- Replay system / game-replay UI — history is in SQL but no dedicated replay viewer for MVP
- Mobile app / native clients — web only
- Customizable roster size / number of Mafia — fixed at 6 players / 2 Mafia for MVP
- Configurable timer length in product mode — fixed 60s; dev mode can override
- OpenAI / local model support — single-provider (Claude) for MVP to keep the LLM integration path focused
- Wippy `framework/views` / `framework/facade` — those target rendered websites; we're building a classic React SPA over WebSocket

## Context

**Developer background & goal.** The developer is actively learning Wippy and chose this project specifically to stress-test the platform with a realistic agentic scenario. Architectural choices should lean toward exercising Wippy primitives rather than shortcutting them — process-per-NPC over a single orchestrator, SQL persistence over in-memory, workflow-driven phase transitions over ad-hoc loops, websocket relay over a hand-rolled transport.

**Audience & distribution.** Personal + small team (the developer's teammates). Local-only. No hosting, no auth, no public exposure. That removes whole tiers of complexity (deploy, identity, rate limiting, abuse handling) and focuses attention on the game loop and NPC quality.

**Wippy primitives expected to be exercised.** `concepts/process-model` (supervised NPC processes), `concepts/workflows` (phase orchestration), `framework/agents` + `framework/llm` (Claude-backed NPC brains), `storage/sql` (game history), `http/server` + `http/websocket-relay` (transport), `core/channel` / `core/events` (inter-process communication between NPCs and the game orchestrator).

**Reference material on hand.** `docs/specs/Single-Player-Mafia-MVP-Business-Spec.md` is the authoritative business spec (already absorbed into these requirements). `docs/reference/wippy-docs-llms.txt` indexes Wippy docs; the `wippy-kb` MCP server is also available for Wippy documentation lookup during planning/execution.

**Environment.** `.env` already contains `ANTHROPIC_API_KEY`, `PUBLIC_API_URL` (default `http://localhost:8080`), and `ENCRYPTION_KEY`. `wippy.lock` exists. This is a fresh project — no prior code, no prior `.planning/` state.

## Constraints

- **Tech stack (backend)**: Wippy — hard requirement. All process orchestration, LLM agents, phase transitions, and game-state logic must run on Wippy.
- **Tech stack (LLM)**: Anthropic Claude via `framework/llm`. `ANTHROPIC_API_KEY` is already in `.env`.
- **Tech stack (frontend)**: React SPA. Communicates with backend exclusively over WebSocket (Wippy's websocket relay).
- **Tech stack (storage)**: SQLite via Wippy's `storage/sql`. Single embedded file, no external DB.
- **Deployment**: Local only (`wippy run`). Must work without hosting infrastructure, DNS, or external services beyond the Anthropic API.
- **Game parameters (fixed for MVP)**: 6 participants, 2 Mafia, 4 Villagers, 60-second day discussion (product mode), 1–2 NPC messages per day round.
- **NPC behavior**: Persona must stay stable across the entire game. NPC voting must be informed (not random) — uses discussion content, prior events, role incentives, and persona.
- **Learning-driven design**: Prefer Wippy-idiomatic solutions over shortcuts, even when a shortcut would save time. The project is an investigation first, a product second.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Backend on Wippy | Non-negotiable — the whole purpose of the project is to learn Wippy | — Pending |
| LLM = Anthropic Claude only | `ANTHROPIC_API_KEY` already in env; keeps LLM integration path focused for MVP | — Pending |
| Frontend = React SPA over WebSocket | User's explicit preference; `framework/views`/`facade` target rendered websites, not SPAs; Wippy has a first-class websocket relay | — Pending |
| Process per NPC (not single orchestrator) | Maximum exercise of Wippy's actor/process model; gives each NPC a natural home for persona + suspicion state | — Pending |
| Hybrid NPC persona generation | Curated pool keeps names/archetypes grounded; LLM adds personality variety for replayability | — Pending |
| SQLite via Wippy SQL for persistence | Restart-safe, browsable history, exercises `storage/sql` — strong learning surface vs. in-memory | — Pending |
| Sequential NPC turn-taking in day chat | Readable as a conversation; player can interject; avoids parallel-chaos UX problems | — Pending |
| Private side-chat for Mafia coordination | Most immersive; showcases a second websocket channel + per-role routing | — Pending |
| Tie = no elimination | Simple, fair, avoids extra UI for revotes; classic house rule | — Pending |
| Reveal role on elimination | Tightens the deduction feedback loop; helps the player actually learn to read NPCs | — Pending |
| Start at Night 1 (kill before Day 1) | Classic Mafia pacing; Day 1 has immediate stakes and discussion signal | — Pending |
| Dev mode is first-class, not afterthought | NPC behavior will require heavy iteration; fast timers + seeded RNG + suspicion inspector pay for themselves many times over | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-21 after initialization*
