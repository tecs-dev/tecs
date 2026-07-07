#!/bin/sh
# Run one love2d bench scenario RUNS times and write the per-metric minimum
# to the output JSON (min = least scheduler/JIT interference; individual
# runs are kept in the "runs" array). Usage:
#   bench_love.sh <love-bin> <app-dir> <scenario> <out.json> [runs]
set -e

LOVE_BIN="$1"
APP_DIR="$2"
SCENARIO="$3"
OUT="$4"
RUNS="${5:-3}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

i=1
while [ "$i" -le "$RUNS" ]; do
    TECS_BENCHMARK=1 TECS_BENCH_SCENARIO="$SCENARIO" TECS_BENCH_OUT="" \
        "$LOVE_BIN" "$APP_DIR" 2>/dev/null | grep TECS_BENCH_RESULT >> "$TMP" \
        || { echo "bench run failed for $SCENARIO" >&2; exit 1; }
    i=$((i + 1))
done

python3 - "$TMP" "$OUT" "$SCENARIO" <<'EOF'
import json
import sys

tmpPath, outPath, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
runs = []
with open(tmpPath) as f:
    for line in f:
        line = line.strip()
        if line.startswith("TECS_BENCH_RESULT "):
            runs.append(json.loads(line.split(" ", 1)[1]))

if not runs:
    print(f"no bench results for {scenario}", file=sys.stderr)
    sys.exit(1)

merged = dict(runs[0])
merged["frameMs"] = {
    key: min(r["frameMs"][key] for r in runs)
    for key in runs[0]["frameMs"]
}
merged["cpuMs"] = {
    key: min(r["cpuMs"][key] for r in runs)
    for key in runs[0].get("cpuMs", {})
}
merged["allocKbPerFrame"] = min(r["allocKbPerFrame"] for r in runs)
merged["runs"] = [
    {
        "frameMs": r["frameMs"],
        "cpuMs": r.get("cpuMs"),
        "allocKbPerFrame": r["allocKbPerFrame"],
    }
    for r in runs
]

with open(outPath, "w") as f:
    json.dump(merged, f)
    f.write("\n")

frame = merged["frameMs"]
cpu = merged.get("cpuMs") or {}
cpuText = f"cpu50={cpu['p50']:.3f}ms " if "p50" in cpu else ""
print(
    f"{scenario}: p50={frame['p50']:.3f}ms {cpuText}mean={frame['mean']:.3f}ms "
    f"p95={frame['p95']:.3f}ms alloc={merged['allocKbPerFrame']:.2f}KB/frame "
    f"({len(runs)} runs, min)"
)
EOF
