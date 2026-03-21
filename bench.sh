#!/bin/bash
# zt Terminal Benchmark Suite
# Compares: zt, st, xterm, alacritty, ghostty
# Simulates low-resource env: 1 CPU core + optional 512MB memory limit
set -euo pipefail

OUTDIR="/home/midasdf/zt/bench-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

ZT=/tmp/zt-release
TASKSET="taskset -c 0"
CONSTRAIN_MEM="systemd-run --user --scope -p MemoryMax=512M -p MemorySwapMax=0"

# Terminal definitions
NAMES=(zt st xterm alacritty ghostty)
declare -A BIN
BIN[zt]="$ZT"
BIN[st]="/usr/local/bin/st"
BIN[xterm]="/usr/bin/xterm"
BIN[alacritty]="/usr/bin/alacritty"
BIN[ghostty]="/usr/bin/ghostty"

# Force pure X11 — unset Wayland to ensure all terminals use X11 via Xvfb
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE
export GDK_BACKEND=x11
export DISPLAY=:96
if ! xdpyinfo -display :96 >/dev/null 2>&1; then
    Xvfb :96 -screen 0 1024x768x24 +extension MIT-SHM &>/dev/null &
    XVFB_PID=$!
    sleep 1
    trap "kill $XVFB_PID 2>/dev/null" EXIT
fi

echo "Display: :96 | CPU: core 0 pinned | Output: $OUTDIR"
echo "Terminals: ${NAMES[*]}"
echo ""

# ─────────────────────────────────────────────
# Generate workload files
# ─────────────────────────────────────────────
echo "Generating workloads..."

# 1. Plain text scroll (100K lines of seq)
seq 1 100000 > /tmp/bench-seq100k.txt

# 2. Dense ASCII (random printable, ~5MB)
python3 -c "
import random, string
rng = random.Random(42)
chars = string.ascii_letters + string.digits + string.punctuation + ' '
for _ in range(60000):
    print(''.join(rng.choices(chars, k=80)))
" > /tmp/bench-dense.txt

# 3. TrueColor (24-bit color lines)
python3 -c "
for i in range(5000):
    r,g,b = i%256, (i*3)%256, (255-i)%256
    print(f'\033[38;2;{r};{g};{b}mLine {i:05d}: The quick brown fox jumps\033[0m')
" > /tmp/bench-truecolor.txt

# 4. Unicode/CJK mix
python3 -c "
lines = [
    'こんにちは世界 Hello World 你好世界',
    'αβγδ εζηθ ικλμ νξοπ ρστυ φχψω',
    '│├─└ ┌┐┘┬┴┤ ═║╔╗╚╝╠╣╦╩╬',
    '█▓▒░ ▀▄▐▌ ◆◇○●□■△▽',
]
for i in range(5000):
    print(lines[i % len(lines)] + f' [{i}]')
" > /tmp/bench-unicode.txt

# 5. Cursor movement stress
python3 -c "
import random
rng = random.Random(42)
for _ in range(50000):
    r = rng.randint(1,24)
    c = rng.randint(1,80)
    print(f'\033[{r};{c}H*', end='')
print('\033[H\033[2J')
" > /tmp/bench-cursor.txt

echo "Workloads ready."
echo ""

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
extract() {
    echo "$1" | grep "$2" | awk '{print $NF}' | head -1
}

wall_to_sec() {
    echo "$1" | awk -F: '{
        if(NF==3) printf "%.4f", $1*3600+$2*60+$3;
        else if(NF==2) printf "%.4f", $1*60+$2;
        else printf "%.4f", $1
    }'
}

run_bench() {
    local name="$1"; shift
    local prefix="$1"; shift
    local bin="${BIN[$name]}"
    /usr/bin/time -v $prefix $bin -e "$@" 2>&1
}

# ─────────────────────────────────────────────
echo "============================================"
echo " 1. STARTUP TIME (hyperfine, 1 core)"
echo "============================================"
echo ""

hyperfine --warmup 5 --min-runs 30 -i --export-json "$OUTDIR/startup.json" \
    --command-name zt        "$TASKSET ${BIN[zt]} -e true 2>/dev/null" \
    --command-name st        "$TASKSET ${BIN[st]} -e true 2>/dev/null" \
    --command-name xterm     "$TASKSET ${BIN[xterm]} -e true 2>/dev/null" \
    --command-name alacritty "$TASKSET ${BIN[alacritty]} -e true 2>/dev/null" \
    --command-name ghostty   "$TASKSET ${BIN[ghostty]} -e true 2>/dev/null" \
    2>&1 | tee "$OUTDIR/startup.txt"

echo ""

# ─────────────────────────────────────────────
echo "============================================"
echo " 2. THROUGHPUT (1 core, unconstrained memory)"
echo "============================================"
echo ""

WORKFILES=(/tmp/bench-seq100k.txt /tmp/bench-dense.txt /tmp/bench-truecolor.txt /tmp/bench-unicode.txt /tmp/bench-cursor.txt)
WORKNAMES=(seq-100k dense-ascii truecolor unicode cursor-stress)
RUNS=5

for wi in "${!WORKFILES[@]}"; do
    wf="${WORKFILES[$wi]}"
    wn="${WORKNAMES[$wi]}"
    wsize=$(stat -c%s "$wf")
    echo "--- $wn ($(numfmt --to=iec $wsize)) ---"
    printf "%-12s %10s %10s %10s %12s\n" "Terminal" "Avg(s)" "CPU(s)" "RSS(KB)" "MB/s"

    for name in "${NAMES[@]}"; do
        wall_sum=0
        cpu_sum=0
        rss_peak=0

        for r in $(seq 1 $RUNS); do
            result=$(run_bench "$name" "$TASKSET" cat "$wf" 2>&1) || true
            w=$(extract "$result" "wall clock")
            cu=$(extract "$result" "User time")
            cs=$(extract "$result" "System time")
            rss=$(extract "$result" "Maximum resident")

            ws=$(wall_to_sec "$w")
            cpus=$(echo "${cu:-0} ${cs:-0}" | awk '{printf "%.4f", $1+$2}')

            wall_sum=$(echo "$wall_sum + $ws" | bc)
            cpu_sum=$(echo "$cpu_sum + $cpus" | bc)
            [ "${rss:-0}" -gt "$rss_peak" ] 2>/dev/null && rss_peak="${rss:-0}"
        done

        wall_avg=$(echo "scale=4; $wall_sum / $RUNS" | bc)
        cpu_avg=$(echo "scale=4; $cpu_sum / $RUNS" | bc)
        mbps=$(echo "scale=1; $wsize / 1048576 / ($wall_avg + 0.0001)" | bc 2>/dev/null || echo "N/A")
        printf "%-12s %10ss %9ss %10s %10s\n" "$name" "$wall_avg" "$cpu_avg" "$rss_peak" "${mbps}"
    done
    echo ""
done 2>&1 | tee "$OUTDIR/throughput.txt"

# ─────────────────────────────────────────────
echo "============================================"
echo " 3. IDLE MEMORY (RSS + PSS)"
echo "============================================"
echo ""

printf "%-12s %10s %10s\n" "Terminal" "RSS(KB)" "PSS(KB)"
for name in "${NAMES[@]}"; do
    bin="${BIN[$name]}"
    $TASKSET $bin -e sleep 30 2>/dev/null &
    TPID=$!
    sleep 3

    if kill -0 $TPID 2>/dev/null; then
        rss=$(ps -o rss= -p $TPID 2>/dev/null | tr -d ' ')
        pss=$(awk '/^Pss:/{s+=$2} END{print s+0}' /proc/$TPID/smaps 2>/dev/null || echo "N/A")
        printf "%-12s %10s %10s\n" "$name" "$rss" "$pss"
        kill $TPID 2>/dev/null; wait $TPID 2>/dev/null || true
    else
        printf "%-12s %10s %10s\n" "$name" "DIED" "-"
    fi
done 2>&1 | tee "$OUTDIR/memory-idle.txt"

echo ""

# ─────────────────────────────────────────────
echo "============================================"
echo " 4. CONSTRAINED: 512MB RAM + 1 core"
echo "    (startup + throughput)"
echo "============================================"
echo ""

echo "--- Startup (10 runs, median) ---"
printf "%-12s %10s\n" "Terminal" "Median(s)"
for name in "${NAMES[@]}"; do
    times=""
    for i in $(seq 1 10); do
        result=$(/usr/bin/time -v $CONSTRAIN_MEM $TASKSET ${BIN[$name]} -e true 2>&1) || true
        w=$(extract "$result" "wall clock")
        ws=$(wall_to_sec "$w")
        times="$times $ws"
    done
    median=$(echo "$times" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{if(NR%2==1) print a[(NR+1)/2]; else printf "%.4f", (a[NR/2]+a[NR/2+1])/2}')
    printf "%-12s %10ss\n" "$name" "$median"
done 2>&1 | tee "$OUTDIR/constrained-startup.txt"

echo ""
echo "--- Throughput: dense-ascii (5 runs, 512MB + 1 core) ---"
printf "%-12s %10s %10s\n" "Terminal" "Avg(s)" "PeakRSS(KB)"
for name in "${NAMES[@]}"; do
    wall_sum=0
    rss_peak=0

    for r in $(seq 1 $RUNS); do
        result=$(run_bench "$name" "$CONSTRAIN_MEM $TASKSET" cat /tmp/bench-dense.txt 2>&1) || true
        w=$(extract "$result" "wall clock")
        rss=$(extract "$result" "Maximum resident")
        ws=$(wall_to_sec "$w")
        wall_sum=$(echo "$wall_sum + $ws" | bc)
        [ "${rss:-0}" -gt "$rss_peak" ] 2>/dev/null && rss_peak="${rss:-0}"
    done

    wall_avg=$(echo "scale=4; $wall_sum / $RUNS" | bc)
    printf "%-12s %10ss %10s\n" "$name" "$wall_avg" "$rss_peak"
done 2>&1 | tee "$OUTDIR/constrained-throughput.txt"

echo ""
echo "============================================"
echo " All benchmarks complete!"
echo " Results: $OUTDIR"
echo "============================================"
