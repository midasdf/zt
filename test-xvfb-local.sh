#!/bin/bash
# zt Xvfb Integration Test Suite
# Runs zt under a headless X server and exercises all features

PASS=0
FAIL=0
TOTAL=0
ZT_DEBUG=/tmp/zt-debug
ZT_RELEASE=/tmp/zt-release
ZT_PID=""
WINDOW_ID=""
XVFB_PID=""

pass() { echo "  PASS: $1"; ((PASS++)); ((TOTAL++)); }
fail() { echo "  FAIL: $1 — $2"; ((FAIL++)); ((TOTAL++)); }
section() { echo ""; echo "=== $1 ==="; }

xdo() {
    xdotool "$@" 2>/dev/null
}

cleanup_zt() {
    if [ -n "$ZT_PID" ] && kill -0 $ZT_PID 2>/dev/null; then
        kill $ZT_PID 2>/dev/null
        wait $ZT_PID 2>/dev/null || true
    fi
    ZT_PID=""
    WINDOW_ID=""
}

launch_zt() {
    local binary="$1"
    $binary &
    ZT_PID=$!
    sleep 2
    WINDOW_ID=$(xdo search --name "zt" | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(xdo search --class "zt" | head -1)
}

type_cmd() {
    if [ -n "$WINDOW_ID" ]; then
        xdo type --window "$WINDOW_ID" --clearmodifiers --delay 10 "$1"
        xdo key --window "$WINDOW_ID" --clearmodifiers Return
    fi
}

send_keys() {
    if [ -n "$WINDOW_ID" ]; then
        xdo key --window "$WINDOW_ID" --clearmodifiers --delay "$@"
    fi
}

alive() {
    kill -0 $ZT_PID 2>/dev/null
}

cleanup_all() {
    cleanup_zt
    [ -n "$XVFB_PID" ] && kill $XVFB_PID 2>/dev/null
    rm -f /tmp/zt-bigfile.txt
}
trap cleanup_all EXIT

# ── Start Xvfb ──
export DISPLAY=:98
Xvfb :98 -screen 0 1024x768x24 +extension MIT-SHM &>/dev/null &
XVFB_PID=$!
sleep 1

if xdpyinfo >/dev/null 2>&1; then
    pass "Xvfb started on :98"
else
    fail "Xvfb" "xdpyinfo failed"
    exit 1
fi

# ── 1. Unit Tests ──
section "1. Unit Tests"
if (cd /home/midasdf/zt && zig build test 2>&1 >/dev/null); then
    pass "zig build test"
else
    fail "zig build test" "failed"
fi

# ── 2. Binary Sanity ──
section "2. Binary Sanity"
RELEASE_SIZE=$(stat -c%s "$ZT_RELEASE")
DEBUG_SIZE=$(stat -c%s "$ZT_DEBUG")
pass "debug: ${DEBUG_SIZE}B, release: ${RELEASE_SIZE}B"
if [ "$RELEASE_SIZE" -lt "$DEBUG_SIZE" ]; then
    pass "release < debug"
else
    fail "size" "release ($RELEASE_SIZE) >= debug ($DEBUG_SIZE)"
fi

# ── 3. Debug Build Launch ──
section "3. Debug Build Launch"
launch_zt "$ZT_DEBUG"
if alive; then pass "zt-debug launched"; else fail "zt-debug" "died immediately"; fi
if [ -n "$WINDOW_ID" ]; then
    pass "zt-debug window created"
    send_keys 50 e c h o space h e l l o Return
    sleep 1
    if alive; then pass "survived keyboard input"; else fail "keyboard" "died"; fi
else
    fail "zt-debug window" "not found"
fi
cleanup_zt

# ── 4. Release Build Launch ──
section "4. Release Build Launch"
launch_zt "$ZT_RELEASE"
if alive; then pass "zt-release launched"; else fail "zt-release" "died immediately"; fi
if [ -n "$WINDOW_ID" ]; then
    pass "zt-release window created"
else
    fail "zt-release window" "not found"
fi
cleanup_zt

# ── 5. Bulk Output ──
section "5. Bulk Output (10K lines)"
seq 1 10000 > /tmp/zt-bigfile.txt
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "cat /tmp/zt-bigfile.txt"
    sleep 8
    if alive; then pass "survived bulk output"; else fail "bulk output" "died during cat"; fi
else
    fail "bulk output" "no window"
fi
cleanup_zt

# ── 6. Rapid Input ──
section "6. Rapid Input (100 keys)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    for i in $(seq 1 100); do
        xdo key --window "$WINDOW_ID" --clearmodifiers --delay 2 a
    done
    xdo key --window "$WINDOW_ID" --clearmodifiers Return
    sleep 1
    if alive; then pass "survived rapid input"; else fail "rapid input" "died"; fi
else
    fail "rapid input" "no window"
fi
cleanup_zt

# ── 7. TrueColor Gradient ──
section "7. TrueColor Gradient (256 values)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'for i in \$(seq 0 255); do printf \"\\e[38;2;\$i;0;0m#\"; done; printf \"\\e[0m\\n\"'"
    sleep 3
    if alive; then pass "survived TrueColor gradient"; else fail "TrueColor" "died"; fi
else
    fail "TrueColor" "no window"
fi
cleanup_zt

# ── 8. 256-Color ──
section "8. 256-Color Palette"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'for i in \$(seq 0 255); do printf \"\\e[48;5;\${i}m \"; done; printf \"\\e[0m\\n\"'"
    sleep 3
    if alive; then pass "survived 256-color palette"; else fail "256-color" "died"; fi
else
    fail "256-color" "no window"
fi
cleanup_zt

# ── 9. TrueColor + Scroll ──
section "9. TrueColor Scroll (200 colored lines)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'for i in \$(seq 1 200); do printf \"\\e[38;2;\$((i%256));128;0mLine %d: ABCDEFGHIJ\\e[0m\\n\" \$i; done'"
    sleep 6
    if alive; then pass "survived TrueColor scroll"; else fail "TrueColor scroll" "died"; fi
else
    fail "TrueColor scroll" "no window"
fi
cleanup_zt

# ── 10. Alt Screen ──
section "10. Alt Screen Switch"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'printf \"\\e[?1049h\"; sleep 1; printf \"Alt screen\\n\"; sleep 1; printf \"\\e[?1049l\"'"
    sleep 4
    if alive; then pass "survived alt screen"; else fail "alt screen" "died"; fi
else
    fail "alt screen" "no window"
fi
cleanup_zt

# ── 11. Cursor Movement Stress ──
section "11. Cursor Movement (500 random jumps)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'for i in \$(seq 1 500); do printf \"\\e[\$((RANDOM%24+1));\$((RANDOM%80+1))H*\"; done; printf \"\\e[H\\e[2J\"'"
    sleep 4
    if alive; then pass "survived cursor stress"; else fail "cursor stress" "died"; fi
else
    fail "cursor stress" "no window"
fi
cleanup_zt

# ── 12. CJK Wide Characters ──
section "12. CJK Wide Characters"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "printf 'こんにちは世界 Hello 你好世界\\n'"
    sleep 2
    if alive; then pass "survived CJK wide chars"; else fail "CJK" "died"; fi
else
    fail "CJK" "no window"
fi
cleanup_zt

# ── 13. Scroll Region ──
section "13. Scroll Region (DECSTBM)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'printf \"\\e[5;20r\"; for i in \$(seq 1 50); do printf \"Region %d\\n\" \$i; done; printf \"\\e[r\"'"
    sleep 3
    if alive; then pass "survived scroll region"; else fail "scroll region" "died"; fi
else
    fail "scroll region" "no window"
fi
cleanup_zt

# ── 14. Erase Operations ──
section "14. Erase Operations (ED/EL)"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'printf \"AAAA\\e[2JBBBB\\e[0JCCCC\\e[1JDDDD\\e[K\\e[1K\\e[2K\"'"
    sleep 2
    if alive; then pass "survived erase ops"; else fail "erase ops" "died"; fi
else
    fail "erase ops" "no window"
fi
cleanup_zt

# ── 15. Insert/Delete Lines & Chars ──
section "15. Insert/Delete Lines & Chars"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    type_cmd "bash -c 'printf \"L1\\nL2\\nL3\\e[2;1H\\e[2L\\e[2M\\e[1;1HABCDEF\\e[1;3H\\e[2P\\e[1;3H\\e[2@\"'"
    sleep 2
    if alive; then pass "survived IL/DL/ICH/DCH"; else fail "IL/DL/ICH/DCH" "died"; fi
else
    fail "IL/DL/ICH/DCH" "no window"
fi
cleanup_zt

# ── 16. SIGTERM ──
section "16. SIGTERM Graceful Shutdown"
launch_zt "$ZT_RELEASE"
if alive; then
    kill -TERM $ZT_PID
    sleep 2
    if ! alive; then
        pass "exited on SIGTERM"
    else
        fail "SIGTERM" "still alive"
        kill -9 $ZT_PID 2>/dev/null; wait $ZT_PID 2>/dev/null || true
    fi
else
    fail "SIGTERM" "wasn't running"
fi
ZT_PID=""

# ── 17. WM_DELETE_WINDOW ──
section "17. WM_DELETE_WINDOW"
launch_zt "$ZT_RELEASE"
if [ -n "$WINDOW_ID" ]; then
    xdo windowclose "$WINDOW_ID"
    sleep 2
    if ! alive; then
        pass "exited on WM_DELETE_WINDOW"
    else
        fail "WM_DELETE_WINDOW" "still alive"
        kill -9 $ZT_PID 2>/dev/null; wait $ZT_PID 2>/dev/null || true
    fi
else
    fail "WM_DELETE_WINDOW" "no window"
fi
ZT_PID=""

# ── Summary ──
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"
[ $FAIL -gt 0 ] && exit 1
exit 0
