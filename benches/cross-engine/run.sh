#!/usr/bin/env bash
# Cross-engine 2D sprite throughput benchmark harness.
# See SPEC.md for the scene contract.
#
# Runs the sweep against each available engine and aggregates RESULT lines
# into results.csv.
#
# Usage:
#   ./run.sh                       # default sweep, all available engines
#   COUNTS="10000 100000" ./run.sh # custom counts
#   ENGINES="tecs bevy" ./run.sh   # restrict engines
#   BENCH_MOVE=0 ./run.sh          # static variant (no per-frame movement)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

COUNTS="${COUNTS:-10000 50000 100000 250000 500000 1000000 2000000}"
ENGINES="${ENGINES:-tecs bevy}"

export BENCH_WARMUP="${BENCH_WARMUP:-2.0}"
export BENCH_MEASURE="${BENCH_MEASURE:-5.0}"
export BENCH_MOVE="${BENCH_MOVE:-1}"

OUT="$HERE/results.csv"
echo "engine,count,frames,mean_ms,fps,low1_fps" > "$OUT"
echo "Writing results to $OUT"
echo "warmup=${BENCH_WARMUP}s measure=${BENCH_MEASURE}s move=${BENCH_MOVE}"
echo

run_one() { # engine count cmd...
    local engine="$1" count="$2"; shift 2
    echo ">>> $engine  N=$count"
    local line
    line="$("$@" 2>/dev/null | grep -m1 '^RESULT,')"
    if [ -n "$line" ]; then
        echo "    $line"
        # strip the leading RESULT, tag → engine,count,frames,mean_ms,fps,low1
        echo "${line#RESULT,}" >> "$OUT"
    else
        echo "    (no RESULT line: crashed, ran out of memory, or no window)"
        echo "$engine,$count,0,0,0,0" >> "$OUT"
    fi
}

# ---------- Tecs ----------
if [[ " $ENGINES " == *" tecs "* ]]; then
    for n in $COUNTS; do
        run_one tecs "$n" env TECS_BENCHMARK=1 \
            make -s -C "$REPO" example-sprite-throughput ENTITIES="$n"
    done
fi

# ---------- Bevy ----------
if [[ " $ENGINES " == *" bevy "* ]]; then
    BEVY_BIN="$HERE/bevy/target/release/sprite-throughput-bevy"
    if [ ! -x "$BEVY_BIN" ]; then
        echo ">>> building bevy (cargo build --release)…"
        ( cd "$HERE/bevy" && cargo build --release )
    fi
    if [ -x "$BEVY_BIN" ]; then
        for n in $COUNTS; do
            run_one bevy "$n" env BEVY_ASSET_ROOT="$HERE/bevy" "$BEVY_BIN" "$n"
        done
    else
        echo ">>> bevy binary missing; skipping (see README for rustc 1.88+ requirement)"
    fi
fi

echo
echo "=== results.csv ==="
column -s, -t "$OUT"
