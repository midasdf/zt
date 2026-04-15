#!/usr/bin/env bash
# run-all.sh — Run all QA smoke scripts and print PASS/FAIL summary
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
SKIP=0

run_script() {
    local script="$1"
    local name
    name="$(basename "$script")"
    local output
    local exit_code

    output=$(bash "$script" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        if echo "$output" | grep -q "^SKIP:"; then
            echo "  SKIP  $name"
            SKIP=$((SKIP + 1))
        else
            echo "  PASS  $name"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL  $name"
        echo "$output" | sed 's/^/         /'
        FAIL=$((FAIL + 1))
    fi
}

echo "=== zt QA Smoke Tests ==="
echo ""

for script in "$SCRIPT_DIR"/0*.sh; do
    run_script "$script"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
