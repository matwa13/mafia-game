import { clsx } from "clsx";

interface BadgeProps {
  variant: "role-mafia" | "role-villager" | "dead" | "neutral";
  children: React.ReactNode;
  className?: string;
}

export function Badge({ variant, children, className }: BadgeProps) {
  return (
    <span
      className={clsx(
        "inline-flex items-center px-2 py-0.5 rounded-sm text-sm font-semibold",
        variant === "role-mafia" && "border-dashed border-2 text-[color:var(--color-role-mafia)]",
        variant === "role-villager" && "border-solid border-2 text-[color:var(--color-role-villager)]",
        variant === "dead" && "border-solid border opacity-60 text-[color:var(--color-role-dead)]",
        variant === "neutral" && "border border-[color:var(--color-border)] text-[color:var(--color-text-muted)]",
        className
      )}
      style={
        variant === "role-mafia"
          ? { borderColor: "var(--color-role-mafia)" }
          : variant === "role-villager"
          ? { borderColor: "var(--color-role-villager)" }
          : variant === "dead"
          ? { borderColor: "var(--color-role-dead)" }
          : undefined
      }
    >
      {children}
    </span>
  );
}
