#!/usr/bin/env bash
# QA 06: Stress throughput — heavy output without parser crash
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: zt binary not found at $ZT"
    exit 0
fi

# seq 1 100000 generates ~600KB of output. Give zt 10 seconds.
timeout 10 "$ZT" -e bash -c '
    seq 1 100000
    exit 0
' && echo "PASS: 06-stress-throughput" || { echo "FAIL: 06-stress-throughput"; exit 1; }
