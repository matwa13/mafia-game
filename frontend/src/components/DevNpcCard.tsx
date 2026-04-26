import type { DevNpcSnapshot } from "../types";

interface Props {
  slot: number;
  npc: DevNpcSnapshot | undefined;
  mafiaSlots: [number, number] | null;
  rosterNames: Record<number, string>;
}

function suspicionColor(score: number): string {
  if (score <= 3) return "var(--color-success)";
  if (score <= 7) return "var(--color-accent)";
  return "var(--color-danger)";
}

export function DevNpcCard({ slot, npc, rosterNames }: Props) {
  const alive = npc?.alive ?? true;
  const role = npc?.role ?? "villager";
  const roleColor = role === "mafia" ? "var(--color-role-mafia)" : "var(--color-role-villager)";
  const deadStyle: React.CSSProperties = alive ? {} : { opacity: 0.6 };

  return (
    <div
      role="region"
      aria-label={`NPC ${npc?.name ?? `slot ${slot}`} internals`}
      className="rounded-md p-3 flex flex-col gap-2"
      style={{
        background: "var(--color-surface)",
        border: "1px solid var(--color-border)",
        borderRadius: "var(--radius-md)",
        ...deadStyle,
      }}
    >
      {/* Header: slot + name + role */}
      <div className="flex items-center justify-between">
        <span
          className="text-sm font-semibold"
          style={{
            color: alive ? "var(--color-text)" : "var(--color-role-dead)",
            textDecoration: alive ? undefined : "line-through",
          }}
        >
          [slot {slot}] {npc?.name ?? "—"}
        </span>
        <span
          className="text-xs font-semibold uppercase"
          style={{ color: roleColor }}
        >
          {role}
        </span>
      </div>

      {/* Archetype + alive label */}
      {npc?.archetype && (
        <div className="text-xs" style={{ color: "var(--color-text-muted)" }}>
          {npc.archetype} · {alive ? "alive" : "dead"}
        </div>
      )}

      {/* Unavailable */}
      {(!npc || npc.unavailable) && (
        <p className="text-xs italic" style={{ color: "var(--color-text-muted)" }}>
          (data unavailable)
        </p>
      )}

      {npc && !npc.unavailable && (
        <>
          {/* Suspicion bars */}
          <div className="flex flex-col gap-1">
            <p className="text-xs font-semibold uppercase" style={{ color: "var(--color-text-muted)" }}>
              Suspicion
            </p>
            {Object.keys(npc.suspicion ?? {}).length === 0 ? (
              <p className="text-xs italic" style={{ color: "var(--color-text-muted)" }}>
                (no suspicion yet)
              </p>
            ) : (
              Object.entries(npc.suspicion).map(([targetSlot, entry]) => {
                const score = entry.score ?? 0;
                const targetName = rosterNames[Number(targetSlot)] ?? `slot ${targetSlot}`;
                return (
                  <div key={targetSlot} className="flex items-center">
                    <span
                      className="text-xs truncate"
                      style={{ width: 80, color: "var(--color-text)", flexShrink: 0 }}
                    >
                      {targetName}
                    </span>
                    <div
                      className="flex-1 mx-2 rounded-full"
                      style={{ height: 4, background: "var(--color-border)" }}
                    >
                      <div
                        className="rounded-full"
                        role="meter"
                        aria-valuenow={score}
                        aria-valuemin={0}
                        aria-valuemax={10}
                        aria-label={`${targetName} suspicion`}
                        style={{
                          height: 4,
                          width: `${(score / 10) * 100}%`,
                          background: suspicionColor(score),
                        }}
                      />
                    </div>
                    <span
                      className="text-xs text-right"
                      style={{ width: 28, color: "var(--color-text-muted)", flexShrink: 0 }}
                    >
                      {score}/10
                    </span>
                  </div>
                );
              })
            )}
          </div>

          {/* Prompt digest */}
          <div className="flex flex-col gap-0.5">
            <p className="text-xs font-semibold uppercase" style={{ color: "var(--color-text-muted)" }}>
              PROMPT DIGEST
            </p>
            {npc.stable_sha ? (
              <p
                className="text-xs font-mono"
                title={npc.stable_sha}
                style={{ color: "var(--color-text-muted)" }}
              >
                stable_sha: {npc.stable_sha.slice(0, 12)}…
              </p>
            ) : null}
            {npc.dynamic_tail ? (
              <p
                className="text-xs font-mono"
                title={npc.dynamic_tail}
                style={{
                  color: "var(--color-text)",
                  overflow: "hidden",
                  display: "-webkit-box",
                  WebkitLineClamp: 2,
                  WebkitBoxOrient: "vertical",
                }}
              >
                {npc.dynamic_tail}
              </p>
            ) : null}
          </div>

          {/* Last vote */}
          {npc.last_vote != null && (
            <div className="text-xs" style={{ color: "var(--color-text-muted)" }}>
              <span className="font-semibold" style={{ color: "var(--color-text)" }}>Last vote</span>{" "}
              Round {npc.last_vote.round} → slot {npc.last_vote.target_slot}{" "}
              {rosterNames[npc.last_vote.target_slot] ? `(${rosterNames[npc.last_vote.target_slot]})` : ""}{" "}
              &ldquo;{npc.last_vote.justification}&rdquo;
            </div>
          )}

          {/* Last pick */}
          {npc.last_pick != null && (
            <div className="text-xs" style={{ color: "var(--color-text-muted)" }}>
              <span className="font-semibold" style={{ color: "var(--color-text)" }}>Last pick</span>{" "}
              Round {npc.last_pick.round} → slot {npc.last_pick.target_slot}{" "}
              {rosterNames[npc.last_pick.target_slot] ? `(${rosterNames[npc.last_pick.target_slot]})` : ""}{" "}
              &ldquo;{npc.last_pick.reasoning}&rdquo;
              {npc.last_pick.confidence ? ` (${npc.last_pick.confidence})` : ""}
            </div>
          )}

          {/* Last LLM error */}
          {npc.last_llm_error != null && (
            <div className="text-xs font-semibold" style={{ color: "var(--color-danger)" }}>
              [ERR] {npc.last_llm_error.type}: {npc.last_llm_error.message}
            </div>
          )}
        </>
      )}
    </div>
  );
}
