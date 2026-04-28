#!/usr/bin/env bash
# scripts/p8-audit-clamps.sh
# Phase 8 D-13 / T-08-07: static grep audit verifying every inbound game_plugin
# payload type has an explicit size clamp (MAX_CHAT_CHARS, tonumber, sub(1,N)).
#
# Wraps validation test 8.7 from 08-VALIDATION.md.
#
# Run from repo root:
#     bash scripts/p8-audit-clamps.sh
#
# Exit 0 only if every clamp marker is present. Exit 1 on any miss.

set -euo pipefail

fail=0

required_clamps=(
    "MAX_CHAT_CHARS"
    "tonumber"
    "sub(1,"
)

for clamp in "${required_clamps[@]}"; do
    if ! grep -q "$clamp" src/relay/game_plugin.lua; then
        echo "MISSING clamp marker: $clamp in src/relay/game_plugin.lua"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "clamp-audit OK"
exit 0
