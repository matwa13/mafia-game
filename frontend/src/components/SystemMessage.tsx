interface SystemMessageProps {
  text: string;
}

export function SystemMessage({ text }: SystemMessageProps) {
  return (
    <div className="flex items-center gap-3 py-2 w-full max-w-[560px] mx-auto">
      <span
        className="flex-1 h-px"
        style={{ background: "var(--color-border)" }}
      />
      <span
        className="text-sm text-center shrink-0"
        style={{ color: "var(--color-text-muted)" }}
      >
        {text}
      </span>
      <span
        className="flex-1 h-px"
        style={{ background: "var(--color-border)" }}
      />
    </div>
  );
}
