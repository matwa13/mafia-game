#!/usr/bin/env bash
# scripts/audit-grep.sh
# Phase 2 Plan 05: build-time grep-gate enforcing two call-site invariants.
#
# D-09 (inherited from Phase 1): events.send only in src/lib/events.lua + src/probes/probe.lua
# D-15 (Phase 2 new):            publish_event.*chat\.line only in src/game/orchestrator.lua
#
# Run from repo root:
#     bash scripts/audit-grep.sh
#
# Exit 0 on pass, 1 on violation. Intended as a pre-commit / CI step and as the
# host-side companion to V-02-10 (which SKIPs in-process because the Wippy
# sandbox strips io.popen).
#
# The greps restrict to *.lua files so documentation comments in *.yaml / *.md
# that reference the literal strings do not register as false-positive
# violations. The invariants are about Lua source-code behavior.

set -euo pipefail

fail=0

# --- D-09: events.send only in the wrapper + the probes legacy entry ---
d09_violations=$(grep -rn --include='*.lua' 'events\.send' src/ \
    | grep -v 'src/lib/events\.lua' \
    | grep -v 'src/probes/probe\.lua' \
    || true)
if [ -n "$d09_violations" ]; then
    echo "D-09 violation: events.send must only appear in src/lib/events.lua + src/probes/probe.lua"
    echo "$d09_violations"
    fail=1
fi

# --- D-15: publish_event(..., "chat.line", ...) only in the orchestrator ---
d15_violations=$(grep -rn --include='*.lua' 'publish_event.*chat\.line' src/ \
    | grep -v 'src/game/orchestrator\.lua' \
    || true)
if [ -n "$d15_violations" ]; then
    echo "D-15 violation: publish_event(..., \"chat.line\", ...) must only appear in src/game/orchestrator.lua"
    echo "$d15_violations"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "grep-audit OK"
exit 0
