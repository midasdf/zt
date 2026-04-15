#!/usr/bin/env bash
# QA 07a: Backend smoke — x11
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out-x11/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: x11 zt binary not found at $ZT"
    exit 0
fi

if [[ -z "${DISPLAY:-}" ]]; then
    echo "SKIP: no DISPLAY set (x11 backend requires X11)"
    exit 0
fi

timeout 3 "$ZT" -e bash -c 'echo ok; exit 0' \
    && echo "PASS: 07-backend-smoke-x11" \
    || { echo "FAIL: 07-backend-smoke-x11"; exit 1; }
