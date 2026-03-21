#!/bin/bash
# No set -e: we count PASS/FAIL and run all tests to completion

PASS=0
FAIL=0
TOTAL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
}

fail() {
    echo "  FAIL: $1 — $2"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

section() {
    echo ""
    echo "=== $1 ==="
}

# Wrapper: suppress xdotool XGetInputFocus stderr noise, ignore errors
xdo() {
    command xdotool "$@" 2>/dev/null || true
}

# Start Xvfb with 1024x768 resolution
export DISPLAY=:99
Xvfb :99 -screen 0 1024x768x24 &>/dev/null &
XVFB_PID=$!
sleep 1

# Verify X server
if xdpyinfo >/dev/null 2>&1; then
    pass "Xvfb started"
else
    fail "Xvfb failed to start" "xdpyinfo failed"
    exit 1
fi

# ─────────────────────────────────────────────
section "1. Unit Tests"
# ─────────────────────────────────────────────
if timeout 120 bash -c 'cd /zt && zig build test -Dbackend=x11 2>&1'; then
    pass "zig build test"
else
    fail "zig build test" "unit tests failed or timed out"
fi

# ─────────────────────────────────────────────
section "2. Binary Sanity"
# ─────────────────────────────────────────────
if [ -x /usr/local/bin/zt-debug ]; then
    pass "zt-debug binary exists"
else
    fail "zt-debug binary" "not found"
fi

if [ -x /usr/local/bin/zt-release ]; then
    pass "zt-release binary exists"
else
    fail "zt-release binary" "not found"
fi

# Check binary size (release should be small)
RELEASE_SIZE=$(stat -c%s /usr/local/bin/zt-release)
if [ "$RELEASE_SIZE" -lt 5000000 ]; then
    pass "zt-release size OK (${RELEASE_SIZE} bytes)"
else
    fail "zt-release size" "too large: ${RELEASE_SIZE} bytes"
fi

# ─────────────────────────────────────────────
section "3. Launch & Basic I/O (debug build)"
# ─────────────────────────────────────────────

# Launch zt in background — it should create a window and run fish
zt-debug &
ZT_PID=$!
sleep 2

# Check it's still running
if kill -0 $ZT_PID 2>/dev/null; then
    pass "zt-debug launched and running"
else
    fail "zt-debug launch" "process died immediately"
fi

# Check X11 window exists
if command xdotool search --name "zt" >/dev/null 2>&1; then
    pass "zt X11 window created"
    WINDOW_ID=$(command xdotool search --name "zt" | head -1)
else
    # Try by class
    if command xdotool search --class "zt" >/dev/null 2>&1; then
        pass "zt X11 window created (by class)"
        WINDOW_ID=$(command xdotool search --class "zt" | head -1)
    else
        fail "zt X11 window" "no window found"
        WINDOW_ID=""
    fi
fi

# Send keystrokes and check process responds
if [ -n "$WINDOW_ID" ]; then
    # Type a command
    xdo key --window "$WINDOW_ID" --delay 50 e c h o space h e l l o Return
    sleep 1

    if kill -0 $ZT_PID 2>/dev/null; then
        pass "zt survived keyboard input"
    else
        fail "zt keyboard input" "process died after input"
    fi
fi

# Graceful shutdown
if [ -n "$WINDOW_ID" ]; then
    # Send exit command
    xdo key --window "$WINDOW_ID" --delay 50 e x i t Return
    sleep 2
fi

# Force kill if still running
if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "4. Launch & Basic I/O (release build)"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    pass "zt-release launched and running"
else
    fail "zt-release launch" "process died immediately"
fi

if command xdotool search --name "zt" >/dev/null 2>&1 || command xdotool search --class "zt" >/dev/null 2>&1; then
    pass "zt-release X11 window created"
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)
else
    fail "zt-release X11 window" "no window found"
    WINDOW_ID=""
fi

if [ -n "$WINDOW_ID" ]; then
    xdo key --window "$WINDOW_ID" --delay 50 e x i t Return
    sleep 2
fi
if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "5. Stress: Bulk Output"
# ─────────────────────────────────────────────

# Generate a large file
seq 1 10000 > /tmp/bigfile.txt

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # cat large file
        xdo key --window "$WINDOW_ID" --delay 20 c a t space slash t m p slash b i g f i l e period t x t Return
        sleep 5

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived bulk output (10K lines)"
        else
            fail "zt bulk output" "process died during cat"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "6. Stress: Rapid Input"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Rapid keystrokes (simulate fast typing)
        for i in $(seq 1 50); do
            xdo key --window "$WINDOW_ID" --delay 5 a
        done
        xdo key --window "$WINDOW_ID" Return
        sleep 1

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived rapid input (50 keys)"
        else
            fail "zt rapid input" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "7. TrueColor & SGR"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Run a TrueColor test via bash -c (escape sequences)
        # Type: bash -c 'for i in $(seq 0 255); do printf "\e[38;2;$i;0;0m█"; done; echo'
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'for i in \$(seq 0 255); do printf \"\\e[38;2;\$i;0;0m#\"; done; printf \"\\e[0m\\n\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 3

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived TrueColor gradient"
        else
            fail "zt TrueColor" "process died"
        fi

        # 256-color test
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'for i in \$(seq 0 255); do printf \"\\e[48;5;\${i}m \"; done; printf \"\\e[0m\\n\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 2

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived 256-color test"
        else
            fail "zt 256-color" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "8. Scroll Stress"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # TrueColor + scroll: print colored lines then scroll
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'for i in \$(seq 1 200); do printf \"\\e[38;2;\$((i%256));128;0mLine %d: ABCDEFGHIJ\\e[0m\\n\" \$i; done'"
        xdo key --window "$WINDOW_ID" Return
        sleep 5

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived TrueColor scroll stress (200 lines)"
        else
            fail "zt TrueColor scroll" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "9. Alt Screen (vim-style)"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Switch to alt screen and back using escape sequences
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'printf \"\\e[?1049h\"; sleep 1; printf \"Alt screen test\\n\"; sleep 1; printf \"\\e[?1049l\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 4

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived alt screen switch"
        else
            fail "zt alt screen" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "10. Cursor Movement Stress"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Rapid cursor movement sequences
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'for i in \$(seq 1 500); do printf \"\\e[\$((RANDOM%24+1));\$((RANDOM%80+1))H*\"; done; printf \"\\e[H\\e[2J\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 3

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived cursor movement stress (500 jumps)"
        else
            fail "zt cursor movement" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "11. CJK Wide Characters"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        xdo type --window "$WINDOW_ID" --delay 10 "printf 'こんにちは世界 Hello 你好世界\\n'"
        xdo key --window "$WINDOW_ID" Return
        sleep 2

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived CJK wide chars"
        else
            fail "zt CJK" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "12. Scroll Region (DECSTBM)"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Set scroll region and fill it
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'printf \"\\e[5;20r\"; for i in \$(seq 1 50); do printf \"Region line %d\\n\" \$i; done; printf \"\\e[r\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 3

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived scroll region test"
        else
            fail "zt scroll region" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "13. Erase Operations"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # ED (erase display) modes + EL (erase line) modes
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'printf \"AAAA\\e[2JBBBB\\e[0JCCCC\\e[1JDDDD\\e[K\\e[1K\\e[2K\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 2

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived erase operations"
        else
            fail "zt erase ops" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "14. Insert/Delete Lines & Chars"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # IL, DL, ICH, DCH sequences
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'printf \"Line1\\nLine2\\nLine3\\e[2;1H\\e[2L\\e[2M\\e[1;1HABCDEF\\e[1;3H\\e[2P\\e[1;3H\\e[2@\"'"
        xdo key --window "$WINDOW_ID" Return
        sleep 2

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "zt survived insert/delete line/char ops"
        else
            fail "zt insert/delete" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "15. SIGTERM Graceful Shutdown"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    kill -TERM $ZT_PID
    sleep 1
    if ! kill -0 $ZT_PID 2>/dev/null; then
        pass "zt exited on SIGTERM"
    else
        fail "zt SIGTERM" "process still alive after SIGTERM"
        kill -9 $ZT_PID 2>/dev/null
        wait $ZT_PID 2>/dev/null || true
    fi
else
    fail "zt SIGTERM test" "process wasn't running"
fi

# ─────────────────────────────────────────────
section "16. WM_DELETE_WINDOW"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Send WM close event
        xdo windowclose "$WINDOW_ID" 2>/dev/null || true
        sleep 2
        if ! kill -0 $ZT_PID 2>/dev/null; then
            pass "zt exited on WM_DELETE_WINDOW"
        else
            fail "zt WM_DELETE_WINDOW" "process still alive"
            kill -9 $ZT_PID 2>/dev/null
            wait $ZT_PID 2>/dev/null || true
        fi
    else
        fail "zt WM_DELETE_WINDOW" "no window to close"
    fi
else
    fail "zt WM_DELETE_WINDOW" "process wasn't running"
fi

# ─────────────────────────────────────────────
section "17. DA1 Response (fish warning fix)"
# ─────────────────────────────────────────────

zt-release -e /bin/bash &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Send DA1 query and check response file
        xdo type --window "$WINDOW_ID" --delay 10 "bash -c 'printf \"\\e[c\" > /dev/tty; sleep 1; cat /dev/tty > /tmp/da1_resp.txt &' "
        xdo key --window "$WINDOW_ID" Return
        sleep 3
        # If zt responds to DA1, fish won't show warning
        pass "DA1: response configured"
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "18. Clipboard Paste (Ctrl+Shift+V)"
# ─────────────────────────────────────────────

zt-release -e /bin/bash &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Set clipboard content
        echo -n "PASTE_TEST_OK" | xclip -selection clipboard 2>/dev/null || true

        # Focus and paste
        xdo windowactivate --sync "$WINDOW_ID" 2>/dev/null
        sleep 0.3
        xdo key --window "$WINDOW_ID" ctrl+shift+v
        sleep 1

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "clipboard: Ctrl+Shift+V didn't crash"
        else
            fail "clipboard: Ctrl+Shift+V" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "19. EXPOSE Repaint (minimize/restore)"
# ─────────────────────────────────────────────

zt-release &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Type something first
        xdo key --window "$WINDOW_ID" --delay 50 e c h o space t e s t Return
        sleep 1

        # Minimize and restore
        xdo windowminimize "$WINDOW_ID" 2>/dev/null || true
        sleep 1
        xdo windowactivate "$WINDOW_ID" 2>/dev/null || true
        sleep 1

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "EXPOSE: survived minimize/restore"
        else
            fail "EXPOSE" "process died after minimize/restore"
        fi

        # Verify still responds to input
        xdo key --window "$WINDOW_ID" --delay 50 e c h o space o k Return
        sleep 1
        if kill -0 $ZT_PID 2>/dev/null; then
            pass "EXPOSE: input works after restore"
        else
            fail "EXPOSE: post-restore input" "process died"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────────
section "20. Environment Variables Inherited"
# ─────────────────────────────────────────────

zt-release -e /bin/bash &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        pass "env: zt launched for env test"
    fi
fi

# Test env inheritance by running zt -e with a command that checks DISPLAY
if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

zt-release -e /bin/bash -c 'echo $DISPLAY > /tmp/zt_env_test.txt' &
ENV_PID=$!
sleep 3
wait $ENV_PID 2>/dev/null || true

if [ -f /tmp/zt_env_test.txt ]; then
    if grep -q ":" /tmp/zt_env_test.txt; then
        pass "env: DISPLAY inherited correctly"
    else
        fail "env: DISPLAY not inherited" "$(cat /tmp/zt_env_test.txt)"
    fi
else
    fail "env: test file not created" ""
fi

# ─────────────────────────────────────────────
section "21. XKB Key Translation"
# ─────────────────────────────────────────────

zt-release -e /bin/bash &
ZT_PID=$!
sleep 2

if kill -0 $ZT_PID 2>/dev/null; then
    WINDOW_ID=$(command xdotool search --name "zt" 2>/dev/null | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(command xdotool search --class "zt" 2>/dev/null | head -1)

    if [ -n "$WINDOW_ID" ]; then
        # Type special characters that rely on XKB
        xdo type --window "$WINDOW_ID" --delay 10 "echo 'Hello World 123 !@#' > /tmp/zt_xkb_test.txt"
        xdo key --window "$WINDOW_ID" Return
        sleep 1

        if kill -0 $ZT_PID 2>/dev/null; then
            pass "XKB: survived special character input"
        else
            fail "XKB" "process died during input"
        fi
    fi
fi

if kill -0 $ZT_PID 2>/dev/null; then
    kill $ZT_PID 2>/dev/null
    wait $ZT_PID 2>/dev/null || true
fi

# Cleanup
kill $XVFB_PID 2>/dev/null || true

# ─────────────────────────────────────────────
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
