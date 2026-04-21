# Single-Player Mafia MVP Business Specification

## 1. Purpose

This document defines the business requirements for the MVP version of a single-player Mafia game.

The MVP is a narrative and social deduction experience in which one human player participates in a Mafia game together with five AI-controlled NPCs. The core value of the experience is not only the hidden-role mechanic itself, but also the social interaction, suspicion-building, bluffing, and voting that emerge through LLM-driven conversations.

This document describes the product behavior and requirements only. It does not define technical implementation details or the delivery plan.

---

## 2. Product Concept

The product is a single-player adaptation of Mafia.

The player joins a game with five AI-controlled characters. At the start of the game, each character receives:
- a hidden role,
- a generated name,
- a generated personality,
- a stable communication style.

The game then progresses through repeated day and night rounds. During the day, all living participants discuss the situation in a shared chat. During the night, the Mafia side selects a victim. After each discussion, all living participants vote to eliminate one suspected Mafia member.

The game ends when either:
- all Mafia members are eliminated, or
- the Mafia team reaches parity with the remaining Villagers.

---

## 3. Scope of the MVP

The MVP must include the following:

- one human player,
- five AI-controlled NPCs,
- a total of six participants in each game,
- exactly two Mafia roles in total,
- exactly four Villager roles in total,
- randomly assigned hidden roles at game start,
- a recurring game loop with Night Phase, Day Discussion Phase, and Voting Phase,
- LLM-driven NPC dialogue,
- stable NPC personalities throughout the entire game,
- player participation in chat and voting,
- automatic NPC voting after each discussion round,
- win and loss conditions,
- clear round progression.

The MVP is expected to provide a playable and coherent game experience rather than a fully featured or highly polished final product.

---

## 4. Out of Scope for This MVP

The following are explicitly out of scope for the MVP unless re-scoped later:

- Doctor role,
- Detective or Sheriff role,
- additional special roles,
- multiplayer with multiple human users,
- advanced progression systems,
- matchmaking,
- monetization features,
- deep customization systems,
- replay system,
- long-term account progression,
- fully finalized frontend stack decision.

These items may be considered in future iterations, but they are not required for MVP acceptance.

---

## 5. Participants and Roles

Each game contains exactly six participants:
- one human player,
- five NPCs.

There are exactly two Mafia roles and four Villager roles in total.

### 5.1 Role Assignment

Roles must be assigned randomly at the beginning of each new game.

The human player may receive either role:
- Mafia, or
- Villager.

### 5.2 Role Visibility

Each participant must know their own role.

Mafia members must know who the other Mafia member is.

Villagers must not know the roles of other participants.

Roles must remain hidden from the player unless revealed through game outcomes or product rules.

---

## 6. NPC Requirements

The game must generate five NPCs at the start of a new session.

Each NPC must have:
- a distinct name,
- a distinct personality,
- a distinct communication style,
- a hidden role,
- alive/dead status,
- the ability to participate in chat,
- the ability to form suspicions and cast votes.

### 6.1 Stable Identity

Each NPC's personality and communication style must remain stable for the duration of the game.

This means NPCs should feel like consistent characters rather than newly regenerated agents on every turn.

### 6.2 Behavioral Expectations

NPC behavior must reflect:
- their assigned role,
- their established personality,
- public conversation history,
- known eliminations,
- previous voting outcomes,
- current suspicions.

Villager NPCs should attempt to identify Mafia members.

Mafia NPCs should attempt to survive, mislead others, deflect suspicion, and help their Mafia partner win.

---

## 7. Core Game Loop

The game must proceed in repeated rounds until a win condition is met.

Each round contains the following phases in order:
1. Night Phase
2. Day Discussion Phase
3. Voting Phase

---

## 8. Night Phase

During the Night Phase, one player is selected for elimination by the Mafia team.

### 8.1 Human as Mafia

If the human player is assigned the Mafia role, the human player must choose the elimination target.

### 8.2 Human as Villager

If the human player is assigned the Villager role, the Night Phase resolves without requiring a player decision.

### 8.3 Night Outcome

Exactly one living participant may be eliminated during a night.

Dead participants must not return to play in later rounds.

No protection mechanics are included in the MVP.

---

## 9. Day Discussion Phase

The Day Discussion Phase is a required and central part of the MVP.

All living participants must be able to take part in a shared conversation.

The purpose of this phase is to allow:
- accusations,
- defense,
- bluffing,
- reasoning,
- persuasion,
- emotional reaction,
- deduction based on prior events.

### 9.1 Shared Chat

The human player and all living NPCs must participate in a shared chat interface or equivalent shared discussion space.

### 9.2 NPC Dialogue Behavior

NPCs must respond in character and in a way that is compatible with:
- their role,
- their personality,
- the current game context,
- the conversation that has already happened.

### 9.3 Discussion Duration

The MVP discussion phase should be time-limited.

The default business requirement is:
- 60 seconds maximum discussion time per day round.

In addition to the time limit, NPC participation may also be constrained to:
- 1 to 2 messages per NPC during a discussion round.

This requirement exists to keep the interaction focused, playable, and bounded.

### 9.4 Chat Locking

Once the discussion phase ends, the chat must be locked.

After chat lock:
- no further messages may be added for that round,
- the game transitions to voting.

---

## 10. Voting Phase

After the discussion phase ends, all living participants vote to eliminate one living participant.

### 10.1 Human Vote

The human player must always vote manually.

There is no timer requirement for the player's vote in the MVP.

### 10.2 NPC Votes

All living NPCs must cast votes automatically after discussion ends.

NPC votes should not be random without context. NPC voting should be informed by:
- the discussion content,
- current suspicion,
- prior events,
- role-based incentives,
- established personality.

### 10.3 Vote Resolution

After all votes are submitted, the participant with the highest number of votes is eliminated.

Dead participants cannot vote.

Only living participants may be voted for.

### 10.4 Tie Handling

If there is a tie for the highest vote count, the product must apply a consistent predefined rule.

The specific tie-breaking rule may be defined later, but the game must not remain unresolved.

---

## 11. Win Conditions

The game must check win conditions after each elimination event.

### 11.1 Villager Victory

The Villager side wins when all Mafia members have been eliminated.

### 11.2 Mafia Victory

The Mafia side wins when the number of living Mafia members is equal to or greater than the number of living Villagers.

---

## 12. Information Model Requirements

From a business perspective, the game must maintain enough state to support coherent and fair gameplay.

At minimum, the product must track:
- all participants,
- role assignments,
- whether each participant is alive or dead,
- current round number,
- current phase,
- chat history,
- discussion outcomes,
- voting outcomes,
- eliminations,
- current suspicions or equivalent reasoning state for NPCs.

The product must preserve enough context for NPCs to behave consistently from round to round.

---

## 13. Platform Expectations

The backend runtime, process orchestration, and LLM-agent behavior for this product must be implemented on Wippy.

This includes, at minimum:
- game process orchestration,
- LLM-powered NPC behavior,
- phase transitions,
- game-state-driven decision flow.

The frontend technology choice is not yet fixed and remains to be decided separately.

This specification intentionally does not prescribe the frontend framework. The frontend should be treated as an open product/engineering decision at this stage.

---

## 14. UX Expectations for the MVP

Although the MVP is not expected to be fully polished, it must provide a coherent playable experience.

The player must be able to understand:
- who is still alive,
- when a new phase begins,
- when discussion is active,
- when discussion has ended,
- when voting is required,
- whether a participant has been eliminated,
- whether the game has been won or lost.

The game should feel understandable and self-contained even in its first MVP form.

---

## 15. Acceptance Criteria

The MVP may be considered functionally complete from a business perspective when all of the following are true:

- a new game can be started,
- five NPCs are generated for the session,
- all roles are assigned correctly,
- the player can receive either Mafia or Villager,
- the game progresses through repeated night/day/voting rounds,
- the discussion phase supports player and NPC participation,
- NPCs speak in stable personas,
- the discussion phase ends after a bounded period,
- the chat is locked before voting,
- the player votes manually,
- NPCs vote automatically,
- eliminations are resolved correctly,
- win/loss conditions are resolved correctly,
- the backend orchestration and LLM-driven logic are handled by Wippy.

---

## 16. Future Considerations

Potential future directions may include:
- additional roles,
- more advanced NPC memory systems,
- richer deduction modeling,
- configurable timers,
- different difficulty levels,
- hidden-role reveal rules,
- stronger UI/UX presentation,
- richer game logs,
- replayability enhancements,
- multiplayer variations.

These are not part of the MVP requirements defined in this specification.
