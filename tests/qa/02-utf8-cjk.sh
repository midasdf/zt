#!/usr/bin/env bash
# QA 02: UTF-8 / CJK wide chars / emoji
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

timeout 3 "$ZT" -e bash -c '
    printf "CJK: あいうえお\n"
    printf "Emoji: 🦀🔥✨\n"
    printf "Arabic: مرحبا\n"
    printf "Combining: e\xcc\x81 (e + combining acute)\n"
    exit 0
' && echo "PASS: 02-utf8-cjk" || { echo "FAIL: 02-utf8-cjk"; exit 1; }
