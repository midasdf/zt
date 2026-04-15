#!/usr/bin/env bash
# QA 04: OSC 0/2 window title with sanitization payload
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

timeout 3 "$ZT" -e bash -c '
    # Normal title
    printf "\e]2;HelloZT\a"
    # Title with embedded control char (BEL terminates early — no crash)
    printf "\e]2;Title\x07Evil\a"
    # Title via ST terminator
    printf "\e]0;StTitle\e\\"
    # Very long title (1024 chars)
    python3 -c "print(\"\\033]2;\" + \"x\"*1024 + \"\\a\", end=\"\")"
    exit 0
' && echo "PASS: 04-osc-title" || { echo "FAIL: 04-osc-title"; exit 1; }
