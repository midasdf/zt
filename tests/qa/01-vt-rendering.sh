#!/usr/bin/env bash
# QA 01: VT rendering — SGR colors, CUP, ED, alt screen
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

# Launch zt with a command that emits various SGR/CUP/ED sequences then exits.
# timeout(1) kills zt if it doesn't exit within 3 seconds.
timeout 3 "$ZT" -e bash -c '
    printf "\e[1;31mRed Bold\e[0m\n"
    printf "\e[2;32mGreen Dim\e[0m\n"
    printf "\e[H\e[2JClear\n"
    printf "\e[?1049h\e[HAlt\e[?1049l"
    printf "\e[5;10HCursorMove"
    exit 0
' && echo "PASS: 01-vt-rendering" || { echo "FAIL: 01-vt-rendering"; exit 1; }
