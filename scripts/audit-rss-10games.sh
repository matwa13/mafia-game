#!/usr/bin/env bash
# scripts/audit-rss-10games.sh
# Phase 5 Plan 06 (D-RR-04 / D-RR-05): one-command RSS audit wrapper.
#
# Boots `wippy run` with stub-mode + dev-mode, samples RSS via `ps -o rss=`
# before and after the V-05-10 RSS soak (10 consecutive game cycles), then
# asserts the D-RR-04 acceptance bar:
#   (after_kb - before_kb) < 10240 KB    (i.e. <10MB absolute growth)
#   AND
#   (after_kb - before_kb) / before_kb < 0.05    (i.e. <5% growth)
#
# Usage (from repo root):
#     bash scripts/audit-rss-10games.sh
#
# Exit 0 on PASS, 1 on FAIL. The script's heuristic sleeps tolerate up to
# ~150s for the 10-cycle stub-mode soak; if the timing becomes flaky in
# practice the developer should run `wippy run` interactively and `ps`
# manually following the [V-05-10] log lines (those are the source of
# truth per D-RR-05).

set -euo pipefail

cd "$(dirname "$0")/.."

# 1. Boot wippy with stub-mode + dev-mode (V-05-10 SKIPs without both).
#    Redirect output to a log file so we can grep for V-05-10 markers
#    if needed for debugging.
WIPPY_LOG="$(mktemp -t mafia-rss-audit.XXXXXX.log)"
trap "rm -f $WIPPY_LOG" EXIT

MAFIA_DEV_MODE=1 MAFIA_NPC_MODE=stub wippy run >"$WIPPY_LOG" 2>&1 &
WIPPY_PID=$!
trap "kill $WIPPY_PID 2>/dev/null || true; rm -f $WIPPY_LOG" EXIT

# 2. Wait for wippy to finish boot. The test_driver runs scenarios at
#    startup; V-05-10 is appended to the Phase 5 dispatch block so it
#    runs after V-05-01..V-05-06e. Heuristic 8s buffer covers boot +
#    Phase 2/3/4/5 prelude tests in stub mode.
sleep 8

# 3. Sample RSS before V-05-10 begins. (V-05-10 is near the end of the
#    Phase 5 block; the prelude tests have warmed any one-time allocations
#    so the BEFORE sample is representative of steady-state RSS.)
BEFORE_KB=$(ps -o rss= -p "$WIPPY_PID" | tr -d ' ')
echo "before_kb=$BEFORE_KB"

# 4. Wait for the V-05-10 loop to complete. 10 stub-mode cycles × ~10-15s
#    each = ~100-150s. Add a 30s safety buffer.
sleep 180

# 5. Sample RSS after the soak.
AFTER_KB=$(ps -o rss= -p "$WIPPY_PID" | tr -d ' ')
echo "after_kb=$AFTER_KB"

# 6. Compute delta (KB) and percentage growth.
DELTA_KB=$((AFTER_KB - BEFORE_KB))
PCT=$(awk -v a="$BEFORE_KB" -v b="$AFTER_KB" \
    'BEGIN { if (a > 0) printf "%.4f", (b - a) / a; else print "0" }')

echo "delta_kb=$DELTA_KB pct_growth=$PCT"

# 7. Acceptance gate per D-RR-04: <10MB absolute AND <5% relative.
if [ "$DELTA_KB" -lt 10240 ] && \
   awk -v p="$PCT" 'BEGIN { exit !(p < 0.05) }'; then
    echo "RSS soak: PASS"
    exit 0
else
    echo "RSS soak: FAIL (delta_kb=$DELTA_KB pct=$PCT; need <10240 AND <0.05)"
    exit 1
fi
