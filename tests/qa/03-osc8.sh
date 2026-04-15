#!/usr/bin/env bash
# QA 03: OSC 8 hyperlinks — allowed + disallowed schemes
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

timeout 3 "$ZT" -e bash -c '
    # Allowed: https
    printf "\e]8;;https://example.com\e\\clickme\e]8;;\e\\\n"
    # Allowed: http
    printf "\e]8;;http://x.example/\e\\http-link\e]8;;\e\\\n"
    # Allowed: file
    printf "\e]8;;file:///tmp/test\e\\file-link\e]8;;\e\\\n"
    # Rejected scheme (ftp) — zt should not crash
    printf "\e]8;;ftp://x/\e\\ftp-link\e]8;;\e\\\n"
    # Rejected scheme (javascript) — zt should not crash
    printf "\e]8;;javascript:alert(1)\e\\xss\e]8;;\e\\\n"
    exit 0
' && echo "PASS: 03-osc8" || { echo "FAIL: 03-osc8"; exit 1; }
