#!/usr/bin/env bash
# QA 07b: Backend smoke — wayland
set -euo pipefail

ZT="${ZT:-$(dirname "$0")/../../zig-out-wayland/bin/zt}"

if [[ ! -x "$ZT" ]]; then
    echo "SKIP: wayland zt binary not found at $ZT"
    exit 0
fi

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "SKIP: no WAYLAND_DISPLAY set (wayland backend requires compositor)"
    exit 0
fi

timeout 3 "$ZT" -e bash -c 'echo ok; exit 0' \
    && echo "PASS: 07-backend-smoke-wayland" \
    || { echo "FAIL: 07-backend-smoke-wayland"; exit 1; }
