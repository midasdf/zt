#!/bin/bash
set -e

# Start Xvfb
Xvfb :99 -screen 0 1024x768x24 -ac -noreset &
sleep 2
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.6

# Verify display
xdpyinfo >/dev/null 2>&1 || { echo "FATAL: Xvfb failed to start"; exit 1; }

# Terminal paths
declare -A TERMS=(
    [zt]="/usr/local/bin/zt"
    [xterm]="/usr/bin/xterm"
    [st]="/usr/local/bin/st"
    [kitty]="/usr/bin/kitty"
    [alacritty]="/usr/bin/alacritty"
    [ghostty]="/usr/bin/ghostty"
)

# Verify terminals exist
echo "=== Terminal versions ==="
for name in zt xterm st kitty alacritty ghostty; do
    cmd="${TERMS[$name]}"
    if [ -x "$cmd" ]; then
        echo "  $name: $cmd (OK)"
    else
        echo "  $name: $cmd (MISSING - skipping)"
        unset TERMS[$name]
    fi
done
echo ""

# Verify each terminal can start
echo "=== Connectivity check ==="
for name in zt xterm st kitty alacritty ghostty; do
    cmd="${TERMS[$name]:-}"
    [ -z "$cmd" ] && continue
    if timeout 10 $cmd -e true >/dev/null 2>&1; then
        echo "  $name: OK"
    else
        echo "  $name: FAIL (removing from bench)"
        unset TERMS[$name]
    fi
done
echo ""

# Build terminal list for hyperfine
STARTUP_ARGS=()
for name in zt xterm st kitty alacritty ghostty; do
    cmd="${TERMS[$name]:-}"
    [ -z "$cmd" ] && continue
    STARTUP_ARGS+=(--command-name "$name" "taskset -c 0 $cmd -e true")
done

# ============================================================
# Benchmark 1: Startup time
# ============================================================
echo "=== Startup time (30 runs, single core) ==="
hyperfine --warmup 5 --min-runs 30 -N -i "${STARTUP_ARGS[@]}" 2>&1
echo ""

# ============================================================
# Benchmark 2: Throughput (4.7MB dense ASCII)
# ============================================================
THROUGHPUT_ARGS=()
for name in zt xterm st kitty alacritty ghostty; do
    cmd="${TERMS[$name]:-}"
    [ -z "$cmd" ] && continue
    THROUGHPUT_ARGS+=(--command-name "$name" "taskset -c 0 $cmd -e cat /tmp/bench-dense.txt")
done

echo "=== Throughput: 4.7MB dense ASCII (10 runs, single core) ==="
hyperfine --warmup 3 --min-runs 10 -N -i "${THROUGHPUT_ARGS[@]}" 2>&1
echo ""

# ============================================================
# Benchmark 3: Peak RSS (idle)
# ============================================================
echo "=== Peak RSS (throughput run) ==="
for name in zt xterm st kitty alacritty ghostty; do
    cmd="${TERMS[$name]:-}"
    [ -z "$cmd" ] && continue
    result=$( /usr/bin/time -v taskset -c 0 $cmd -e cat /tmp/bench-dense.txt 2>&1 || true )
    rss=$( echo "$result" | grep "Maximum resident" | grep -oP '\d+$' || echo "0" )
    if [ "$rss" -gt 0 ] 2>/dev/null; then
        rss_mb=$(echo "scale=1; $rss / 1024" | bc)
        printf "  %-12s  %s MB\n" "$name" "$rss_mb"
    else
        printf "  %-12s  (failed)\n" "$name"
    fi
done
echo ""

echo "=== Benchmark complete ==="
