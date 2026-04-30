import { useEffect, useRef } from "react";

interface DialogProps {
  open: boolean;
  children: React.ReactNode;
  className?: string;
}

export function Dialog({ open, children, className }: DialogProps) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (open && !el.open) {
      el.showModal();
    } else if (!open && el.open) {
      el.close();
    }
  }, [open]);

  return (
    <dialog
      ref={ref}
      className={className}
      style={{
        background: "transparent",
        border: "none",
        padding: 0,
        maxWidth: "none",
        maxHeight: "none",
      }}
    >
      {children}
    </dialog>
  );
}
