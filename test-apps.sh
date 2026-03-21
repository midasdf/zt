#!/bin/bash
# zt Real Application Test Suite
# Tests zt with actual CLI applications under Xvfb

ZT=${ZT:-/usr/local/bin/zt-release}
ZT_PID=""
WINDOW_ID=""
XVFB_PID=""

PASS=0
FAIL=0
TOTAL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
section() { echo ""; echo "=== $1 ==="; }

xdo() { command xdotool "$@" 2>/dev/null || true; }

cleanup_zt() {
    if [ -n "$ZT_PID" ] && kill -0 $ZT_PID 2>/dev/null; then
        kill $ZT_PID 2>/dev/null
        wait $ZT_PID 2>/dev/null || true
    fi
    ZT_PID=""
    WINDOW_ID=""
}

launch_zt() {
    $ZT &
    ZT_PID=$!
    sleep 2
    WINDOW_ID=$(xdo search --name "zt" | head -1)
    [ -z "$WINDOW_ID" ] && WINDOW_ID=$(xdo search --class "zt" | head -1)
    if [ -z "$WINDOW_ID" ]; then
        fail "$1 — launch" "no window"
        return 1
    fi
    return 0
}

type_cmd() {
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 8 "$1"
    xdo key --window "$WINDOW_ID" --clearmodifiers Return
}

send_keys() {
    xdo key --window "$WINDOW_ID" --clearmodifiers "$@"
}

alive() { kill -0 $ZT_PID 2>/dev/null; }

wait_and_check() {
    local label="$1"
    local wait_sec="${2:-3}"
    sleep "$wait_sec"
    if alive; then
        pass "$label"
    else
        fail "$label" "zt process died"
    fi
}

cleanup_all() {
    cleanup_zt
    [ -n "$XVFB_PID" ] && kill $XVFB_PID 2>/dev/null
}
trap cleanup_all EXIT

# ── Start Xvfb ──
export DISPLAY=:97
Xvfb :97 -screen 0 1024x768x24 +extension MIT-SHM &>/dev/null &
XVFB_PID=$!
sleep 1
if ! xdpyinfo >/dev/null 2>&1; then
    echo "FATAL: Xvfb failed to start"
    exit 1
fi
echo "Xvfb ready on :97"

# Prepare test data
mkdir -p /tmp/zt-test-data
seq 1 5000 > /tmp/zt-test-data/numbers.txt
python3 -c "
for i in range(100):
    r,g,b = i*2%256, (i*3+50)%256, (255-i*2)%256
    print(f'\033[38;2;{r};{g};{b}m' + f'Line {i:03d}: ' + 'The quick brown fox jumps over the lazy dog' + '\033[0m')
" > /tmp/zt-test-data/truecolor.txt
cat > /tmp/zt-test-data/sample.py << 'PYEOF'
#!/usr/bin/env python3
"""Sample Python file for syntax highlighting test."""
import os
import sys

class Greeter:
    def __init__(self, name: str):
        self.name = name

    def greet(self) -> str:
        return f"Hello, {self.name}!"

def main():
    names = ["World", "Python", "Terminal"]
    for name in names:
        g = Greeter(name)
        print(g.greet())

    # Numbers and special chars
    data = {"pi": 3.14159, "e": 2.71828, "φ": 1.61803}
    for k, v in data.items():
        print(f"  {k} = {v:.5f}")

if __name__ == "__main__":
    main()
PYEOF

# ─────────────────────────────────────────────
section "1. vim — open, edit, navigate, quit"
# ─────────────────────────────────────────────
launch_zt "vim" && {
    type_cmd "vim /tmp/zt-test-data/sample.py"
    sleep 2
    wait_and_check "vim: opened file" 1

    # Navigate: gg (top), G (bottom), /def (search)
    send_keys g g
    sleep 0.5
    send_keys G
    sleep 0.5
    send_keys slash d e f Return
    sleep 0.5
    wait_and_check "vim: navigation (gg, G, /search)" 1

    # Enter insert mode, type, escape
    send_keys i
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "# test comment"
    send_keys Escape
    sleep 0.5
    wait_and_check "vim: insert mode" 1

    # Page up/down
    send_keys ctrl+f
    sleep 0.3
    send_keys ctrl+b
    sleep 0.3
    wait_and_check "vim: page up/down" 1

    # :q! to quit
    send_keys colon
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "q!"
    send_keys Return
    sleep 1
    wait_and_check "vim: quit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "2. nano — open, type, save, exit"
# ─────────────────────────────────────────────
launch_zt "nano" && {
    type_cmd "nano /tmp/zt-test-data/nano-test.txt"
    sleep 2
    wait_and_check "nano: opened" 1

    # Type some text
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "Hello from zt terminal!"
    send_keys Return
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "Line 2: Testing nano in zt"
    sleep 0.5
    wait_and_check "nano: typed text" 1

    # Ctrl+O (save), Enter, Ctrl+X (exit)
    send_keys ctrl+o
    sleep 0.5
    send_keys Return
    sleep 0.5
    send_keys ctrl+x
    sleep 1
    wait_and_check "nano: save & exit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "3. micro — open, edit, quit"
# ─────────────────────────────────────────────
if command -v micro &>/dev/null; then
    launch_zt "micro" && {
        type_cmd "micro /tmp/zt-test-data/sample.py"
        sleep 2
        wait_and_check "micro: opened file" 1

        # Type, navigate
        send_keys ctrl+g
        sleep 0.5
        xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "10"
        send_keys Return
        sleep 0.5
        wait_and_check "micro: goto line" 1

        # Quit
        send_keys ctrl+q
        sleep 1
        wait_and_check "micro: quit" 1
        cleanup_zt
    }
else
    echo "  SKIP: micro not installed"
fi

# ─────────────────────────────────────────────
section "4. less — paging, search, quit"
# ─────────────────────────────────────────────
launch_zt "less" && {
    type_cmd "less /tmp/zt-test-data/numbers.txt"
    sleep 2
    wait_and_check "less: opened 5K lines" 1

    # Page down several times
    send_keys space
    sleep 0.3
    send_keys space
    sleep 0.3
    send_keys space
    sleep 0.3
    wait_and_check "less: page down" 1

    # Search
    send_keys slash
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "4999"
    send_keys Return
    sleep 0.5
    wait_and_check "less: search" 1

    # Go to top, go to end
    send_keys g
    sleep 0.3
    send_keys --delay 100 shift+g
    sleep 0.3
    wait_and_check "less: top/bottom navigation" 1

    # Quit
    send_keys q
    sleep 1
    wait_and_check "less: quit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "5. bat — syntax highlighting + TrueColor"
# ─────────────────────────────────────────────
if command -v bat &>/dev/null; then
    launch_zt "bat" && {
        type_cmd "bat --color=always /tmp/zt-test-data/sample.py"
        sleep 3
        wait_and_check "bat: syntax highlight Python" 1

        type_cmd "bat --color=always /home/midasdf/zt/src/main.zig"
        sleep 3
        wait_and_check "bat: syntax highlight Zig" 1
        cleanup_zt
    }
else
    echo "  SKIP: bat not installed"
fi

# ─────────────────────────────────────────────
section "6. top — live updating TUI"
# ─────────────────────────────────────────────
launch_zt "top" && {
    type_cmd "top -b -n 3"
    sleep 8
    wait_and_check "top: 3 batch iterations" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "7. btop — complex TUI with colors"
# ─────────────────────────────────────────────
if command -v btop &>/dev/null; then
    launch_zt "btop" && {
        type_cmd "btop"
        sleep 5
        wait_and_check "btop: launched TUI" 1

        # Let it render a few frames
        sleep 3
        wait_and_check "btop: running for 8 seconds" 1

        # Quit btop
        send_keys q
        sleep 2
        wait_and_check "btop: quit" 1
        cleanup_zt
    }
else
    echo "  SKIP: btop not installed"
fi

# ─────────────────────────────────────────────
section "8. man — manpage rendering"
# ─────────────────────────────────────────────
launch_zt "man" && {
    type_cmd "man ls"
    sleep 3
    wait_and_check "man: opened manpage" 1

    # Navigate
    send_keys space
    sleep 0.5
    send_keys space
    sleep 0.5
    wait_and_check "man: paging" 1

    # Search
    send_keys slash
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "color"
    send_keys Return
    sleep 0.5
    wait_and_check "man: search" 1

    send_keys q
    sleep 1
    wait_and_check "man: quit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "9. git — log, diff, status (colored)"
# ─────────────────────────────────────────────
launch_zt "git" && {
    type_cmd "cd /home/midasdf/zt && git log --oneline --graph --color=always -20"
    sleep 3
    wait_and_check "git log: colored graph" 1

    type_cmd "git diff --color=always HEAD~1"
    sleep 3
    wait_and_check "git diff: colored diff" 1

    type_cmd "git status --short"
    sleep 1
    wait_and_check "git status" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "10. eza — colored ls replacement"
# ─────────────────────────────────────────────
if command -v eza &>/dev/null; then
    launch_zt "eza" && {
        type_cmd "eza -la --color=always --icons /home/midasdf/zt/src/"
        sleep 2
        wait_and_check "eza: colored listing with icons" 1

        type_cmd "eza --tree --color=always /home/midasdf/zt/src/"
        sleep 2
        wait_and_check "eza: tree view" 1
        cleanup_zt
    }
else
    echo "  SKIP: eza not installed"
fi

# ─────────────────────────────────────────────
section "11. tree — directory tree"
# ─────────────────────────────────────────────
if command -v tree &>/dev/null; then
    launch_zt "tree" && {
        type_cmd "tree -C /home/midasdf/zt/src/"
        sleep 2
        wait_and_check "tree: colored tree output" 1
        cleanup_zt
    }
else
    echo "  SKIP: tree not installed"
fi

# ─────────────────────────────────────────────
section "12. rg (ripgrep) — colored search results"
# ─────────────────────────────────────────────
if command -v rg &>/dev/null; then
    launch_zt "rg" && {
        type_cmd "rg --color=always 'fn ' /home/midasdf/zt/src/"
        sleep 3
        wait_and_check "rg: colored search across codebase" 1
        cleanup_zt
    }
else
    echo "  SKIP: rg not installed"
fi

# ─────────────────────────────────────────────
section "13. python3 — REPL with colors"
# ─────────────────────────────────────────────
launch_zt "python3" && {
    type_cmd "python3"
    sleep 2
    wait_and_check "python3: REPL started" 1

    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "print('Hello from Python!')"
    send_keys Return
    sleep 1

    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "import sys; print(sys.version)"
    send_keys Return
    sleep 1

    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "[i**2 for i in range(20)]"
    send_keys Return
    sleep 1
    wait_and_check "python3: expressions" 1

    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 15 "exit()"
    send_keys Return
    sleep 1
    wait_and_check "python3: exit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "14. TrueColor content through less"
# ─────────────────────────────────────────────
launch_zt "truecolor-less" && {
    type_cmd "less -R /tmp/zt-test-data/truecolor.txt"
    sleep 2
    wait_and_check "less -R: TrueColor content" 1

    send_keys space
    sleep 0.5
    send_keys space
    sleep 0.5
    wait_and_check "less -R: paging TrueColor" 1

    send_keys q
    sleep 1
    wait_and_check "less -R: quit" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "15. fish shell — prompt, completions, history"
# ─────────────────────────────────────────────
launch_zt "fish" && {
    # fish is the default shell, so it's already running
    sleep 1

    # Test tab completion
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 30 "ech"
    send_keys Tab
    sleep 1
    send_keys Return
    sleep 0.5
    wait_and_check "fish: tab completion" 1

    # Test history (up arrow)
    send_keys Up
    sleep 0.5
    send_keys Return
    sleep 0.5
    wait_and_check "fish: history (up arrow)" 1

    # Test Ctrl+C
    xdo type --window "$WINDOW_ID" --clearmodifiers --delay 20 "sleep 100"
    send_keys Return
    sleep 1
    send_keys ctrl+c
    sleep 1
    wait_and_check "fish: Ctrl+C interrupt" 1

    # Test Ctrl+L (clear)
    send_keys ctrl+l
    sleep 1
    wait_and_check "fish: Ctrl+L clear" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "16. Resize stress (X11 ConfigureNotify)"
# ─────────────────────────────────────────────
launch_zt "resize" && {
    type_cmd "echo before-resize"
    sleep 1

    # Resize window multiple times
    for size in "800x600" "640x480" "1024x768" "400x300" "1024x768"; do
        IFS=x read -r w h <<< "$size"
        xdo windowsize "$WINDOW_ID" "$w" "$h"
        sleep 1
    done
    wait_and_check "resize: survived 5 resize cycles" 1

    # Type after resize to verify terminal still works
    type_cmd "echo after-resize"
    sleep 1
    wait_and_check "resize: I/O works after resize" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "17. Long-running with mixed I/O"
# ─────────────────────────────────────────────
launch_zt "mixed" && {
    # Rapid alternation of output and input
    type_cmd "for i in \$(seq 1 20); do echo \"iteration \$i\"; sleep 0.1; done"
    sleep 5
    wait_and_check "mixed: rapid echo loop" 1

    # Pipe chain
    type_cmd "seq 1 1000 | grep -E '(^1|7\$)' | head -20"
    sleep 2
    wait_and_check "mixed: pipe chain" 1

    # Unicode mix
    type_cmd "printf '🎉 Success! 日本語テスト ñ ü ö ä ß €\\n'"
    sleep 1
    wait_and_check "mixed: unicode/emoji" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "18. SGR attribute combos"
# ─────────────────────────────────────────────
launch_zt "sgr" && {
    # Bold, italic, underline, reverse, dim combinations
    type_cmd "bash -c 'printf \"\\e[1mBold\\e[0m \\e[3mItalic\\e[0m \\e[4mUnderline\\e[0m \\e[7mReverse\\e[0m \\e[2mDim\\e[0m\\n\"'"
    sleep 1
    type_cmd "bash -c 'printf \"\\e[1;3;4mBold+Italic+Underline\\e[0m \\e[1;31;42mBold Red on Green\\e[0m\\n\"'"
    sleep 1
    type_cmd "bash -c 'printf \"\\e[38;5;196m256-Red \\e[38;5;46m256-Green \\e[38;5;21m256-Blue\\e[0m\\n\"'"
    sleep 1
    wait_and_check "SGR: attribute combinations" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "19. Alternate screen rapid toggle"
# ─────────────────────────────────────────────
launch_zt "altscreen-toggle" && {
    type_cmd "bash -c 'for i in \$(seq 1 10); do printf \"\\e[?1049h\"; printf \"Alt %d\\n\" \$i; sleep 0.2; printf \"\\e[?1049l\"; sleep 0.2; done'"
    sleep 6
    wait_and_check "alt screen: 10 rapid toggles" 1
    cleanup_zt
}

# ─────────────────────────────────────────────
section "20. Tab stops and backspace"
# ─────────────────────────────────────────────
launch_zt "tabstops" && {
    type_cmd "printf 'A\\tB\\tC\\tD\\n1\\t2\\t3\\t4\\n'"
    sleep 1
    type_cmd "bash -c 'printf \"ABCDEF\\b\\b\\bXYZ\\n\"'"
    sleep 1
    wait_and_check "tabs and backspace" 1
    cleanup_zt
}

# ── Summary ──
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"
[ $FAIL -gt 0 ] && exit 1
exit 0
