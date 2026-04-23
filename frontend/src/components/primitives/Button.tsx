import { clsx } from "clsx";
import type { ButtonHTMLAttributes } from "react";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "secondary" | "ghost";
  size?: "md" | "lg";
}

export function Button({
  variant = "primary",
  size = "md",
  className,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      className={clsx(
        "inline-flex items-center justify-center rounded-md font-semibold cursor-pointer transition-opacity disabled:opacity-40 disabled:cursor-not-allowed",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
        size === "md" && "px-4 py-2 text-sm min-h-[36px]",
        size === "lg" && "px-6 py-3 text-base min-h-[44px]",
        variant === "primary" && "text-black",
        variant === "secondary" && "border border-[color:var(--color-border)] bg-transparent text-[color:var(--color-text)] hover:bg-[color:var(--color-surface-raised)]",
        variant === "ghost" && "bg-transparent text-[color:var(--color-text-muted)] hover:text-[color:var(--color-text)]",
        className
      )}
      style={
        variant === "primary"
          ? { backgroundColor: "var(--color-accent)", outlineColor: "var(--color-accent)" }
          : { outlineColor: "var(--color-accent)" }
      }
      {...props}
    >
      {children}
    </button>
  );
}
