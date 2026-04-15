#!/usr/bin/env bash
# QA 05: Bracketed paste mode — enable/disable without crash
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

# Enable bracketed paste, then send the end-marker embedded in output.
# zt itself receives this from the child program — it should not crash.
# The child just prints and exits, zt should exit cleanly.
timeout 3 "$ZT" -e bash -c '
    # Enable bracketed paste mode
    printf "\e[?2004h"
    # Print the end-of-paste marker string (from child stdout, not from paste path)
    # zt receives this via PTY reads, not via clipboard paste; it just renders it.
    printf "paste-marker-test: \e[201~\n"
    # Disable bracketed paste mode
    printf "\e[?2004l"
    exit 0
' && echo "PASS: 05-bracketed-paste" || { echo "FAIL: 05-bracketed-paste"; exit 1; }
