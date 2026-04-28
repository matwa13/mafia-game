#!/usr/bin/env bash
# scripts/p8-smoke.sh
# Phase 8: deployment smoke runner. Wraps tests 8.1a–8.9 from 08-VALIDATION.md
# into a single entry point so every task / wave can be sampled.
#
# Usage:
#   bash scripts/p8-smoke.sh quick
#       Runs only the no-VPS checks: 8.7 (clamp audit), 8.9 (frontend dist wss://).
#       Suitable for per-task sampling.
#
#   bash scripts/p8-smoke.sh full
#       Runs the full curl/wscat set against a deployed VPS. Requires:
#           MAFIA_HOST (e.g. mafia.example.com)
#           MAFIA_USER (basic-auth username)
#           MAFIA_PASS (basic-auth password)
#       Skips checks whose env vars are missing rather than failing — the message
#       names what was skipped.
#
# Exit 0 on pass, 1 on any violation.

set -euo pipefail

MODE="${1:-quick}"
fail=0

ok()   { echo "PASS  $1"; }
miss() { echo "FAIL  $1"; fail=1; }
skip() { echo "SKIP  $1 ($2)"; }

# -----------------------------------------------------------------------------
# Always-run (no VPS required): 8.7, 8.9
# -----------------------------------------------------------------------------

# 8.7 — static clamp audit (D-13 / T-08-07)
if bash scripts/p8-audit-clamps.sh > /dev/null 2>&1; then
    ok "8.7 static clamp audit"
else
    miss "8.7 static clamp audit (run scripts/p8-audit-clamps.sh for detail)"
fi

# 8.9 — frontend dist uses wss:// scheme switch (T-08-08)
# Looks for protocol-detection idiom in built JS. The fix is in frontend/src/ws.ts.
# SKIP when wss:// absent: Plan 02 owns the ws.ts fix and dist rebuild.
# full+MAFIA_HOST: FAIL if wss:// absent — VPS smoke requires a rebuilt dist.
_8_9_host="${MAFIA_HOST:-}"
if [ -d frontend/dist/assets ]; then
    if grep -q '"wss:"' frontend/dist/assets/*.js 2>/dev/null \
       || grep -q "'wss:'" frontend/dist/assets/*.js 2>/dev/null; then
        ok "8.9 frontend dist has wss:// scheme"
    elif [ "$MODE" = "full" ] && [ -n "$_8_9_host" ]; then
        miss "8.9 frontend dist is missing wss:// — rebuild with npm run build after fixing ws.ts"
    else
        skip "8.9 frontend dist wss://" "dist exists but wss:// not yet present — Plan 02 fixes ws.ts and rebuilds"
    fi
else
    skip "8.9 frontend dist" "frontend/dist/assets not built; run npm run build in frontend/"
fi

# -----------------------------------------------------------------------------
# VPS-required checks (full mode only): 8.1a, 8.1b, 8.1c, 8.3, 8.5, 8.8
# -----------------------------------------------------------------------------

if [ "$MODE" = "full" ]; then
    HOST="${MAFIA_HOST:-}"
    USER="${MAFIA_USER:-}"
    PASS="${MAFIA_PASS:-}"

    if [ -z "$HOST" ]; then
        skip "VPS smoke set" "MAFIA_HOST not set"
    else
        # 8.1a — anonymous HTTP request returns 401 (D-03 / T-08-01)
        code=$(curl -I -s -o /dev/null -w "%{http_code}" "https://${HOST}/" || true)
        if [ "$code" = "401" ]; then ok "8.1a anonymous HTTP → 401"
        else miss "8.1a expected 401 got ${code}"
        fi

        # 8.1b — anonymous WebSocket upgrade returns 401 (D-03 / T-08-02)
        code=$(curl -I -s --http1.1 \
            -H "Upgrade: websocket" -H "Connection: Upgrade" \
            -o /dev/null -w "%{http_code}" \
            "https://${HOST}/ws/" || true)
        if [ "$code" = "401" ]; then ok "8.1b anonymous WS upgrade → 401"
        else miss "8.1b expected 401 got ${code}"
        fi

        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            # 8.1c — authenticated HTTP request succeeds (D-03)
            code=$(curl -I -s -u "${USER}:${PASS}" \
                -o /dev/null -w "%{http_code}" "https://${HOST}/" || true)
            if [ "$code" = "200" ]; then ok "8.1c authenticated HTTP → 200"
            else miss "8.1c expected 200 got ${code}"
            fi

            # 8.3 — origin allowlist enforcement (D-11 / T-08-03)
            code=$(curl -I -s -u "${USER}:${PASS}" \
                -H "Origin: https://evil.com" \
                -H "Upgrade: websocket" -H "Connection: Upgrade" \
                -o /dev/null -w "%{http_code}" \
                "https://${HOST}/ws/" || true)
            if [ "$code" = "403" ]; then ok "8.3 evil-origin → 403"
            else miss "8.3 expected 403 got ${code}"
            fi

            # 8.8 — Caddy emits security headers (D-13)
            headers=$(curl -I -s -u "${USER}:${PASS}" "https://${HOST}/" || true)
            count=$(echo "$headers" | grep -ciE \
                "^(Content-Security-Policy|X-Frame-Options|X-Content-Type-Options|Referrer-Policy|Strict-Transport-Security):" \
                || true)
            if [ "$count" -ge 5 ]; then ok "8.8 security headers (${count}/5 present)"
            else miss "8.8 expected 5 security headers got ${count}"
            fi
        else
            skip "8.1c / 8.3 / 8.8" "MAFIA_USER and/or MAFIA_PASS not set"
        fi

        # 8.5 — dev mode hard-off (operator runs on VPS host)
        skip "8.5 dev-mode-off" "manual: SSH to VPS and check wippy.log"
    fi
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "p8-smoke OK"
exit 0
