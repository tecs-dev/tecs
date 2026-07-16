#!/usr/bin/env bash
# Orchestrate one unattended "one-shot" eval: scaffold a fresh game project
# with the working-tree CLI (dist/tecs), launch a headless Claude session in
# it with a game prompt, time it, capture token usage, ask the agent for a
# debrief, and collect the transcript — everything lands in
# /tmp/oneshot<N>-results/ for review, with meta.json recording game, model,
# and CLI version so cross-run comparisons stay honest.
#
# Usage:
#   scripts/oneshot.sh [-g game] [-m model] [N] [prompt...]
#     -g game   named preset: snake (default), breakout, match3, asteroids,
#               platformer
#     -m model  forwarded to `claude --model` (opus, sonnet, haiku, fable,
#               or a full model id); omit for the session default
#     N         run number (default: next free /tmp/oneshot<N>)
#     prompt    explicit prompt override (wins over -g)
#
# The nested Claude runs with --dangerously-skip-permissions so the run is
# fully unattended; only launch this against scratch projects.

set -euo pipefail

# The whole script runs inside main() so bash parses the entire file before
# executing anything: editing this file while a run is in flight can no longer
# corrupt the running copy (bash otherwise reads scripts lazily by byte offset).
main() {

root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/dist:$PATH"

# --- options ------------------------------------------------------------------
game="snake"
model=""
while [ $# -gt 0 ]; do
    case "$1" in
        -g) game="$2"; shift 2 ;;
        -m) model="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

# Every preset ends with the same stop-there clause so runs stay comparable;
# each game stresses a different subsystem (grid ticks, continuous collision,
# staged-mutation churn + mouse, trait queries, fixed timestep + held input).
stop_there="Stop there -- no integration specs, README prose, or extra polish."
case "$game" in
    snake)
        game_prompt="oneshot create a nibbles game with tecs and tecs2d. Done means: core mechanics (steer, eat, grow, die, restart) implemented and verified working in the live game. $stop_there" ;;
    breakout)
        game_prompt="oneshot create a breakout game with tecs and tecs2d. Done means: paddle control, ball bouncing off walls/paddle/bricks with sane angles, brick destruction, lives, and restart implemented and verified working in the live game. $stop_there" ;;
    match3)
        game_prompt="oneshot create a match-3 puzzle game with tecs and tecs2d. Done means: click-to-swap adjacent gems, match detection, cascading refills, score, and a no-more-moves reshuffle implemented and verified working in the live game. $stop_there" ;;
    asteroids)
        game_prompt="oneshot create an asteroids game with tecs and tecs2d. Done means: ship rotation and thrust, screen wrapping, shooting, asteroids that split when hit, lives, and restart implemented and verified working in the live game. $stop_there" ;;
    platformer)
        game_prompt="oneshot create a single-screen platformer with tecs and tecs2d. Done means: run and jump with gravity, landing on platforms, a collectible, a hazard that resets you, and camera following the player, all verified working in the live game. $stop_there" ;;
    *)
        echo "ERROR: unknown game '$game' (snake, breakout, match3, asteroids, platformer)" >&2
        exit 1 ;;
esac

# --- resolve run number and paths -------------------------------------------
n="${1:-}"
if [ -z "$n" ]; then
    n=1
    while [ -e "/tmp/oneshot$n" ]; do n=$((n + 1)); done
else
    shift || true
fi
prompt="${*:-$game_prompt}"

model_args=()
if [ -n "$model" ]; then
    model_args=(--model "$model")
fi

project="/tmp/oneshot$n"
results="/tmp/oneshot$n-results"

debrief_prompt='Debrief this session honestly: (1) Did the tecs MCP bridge tools work the whole time — and did you actually use them? (2) Where did the time and tokens go; what was wasted? (3) What did you try that failed, and why? (4) What one or two changes to the project guidance or tecs tooling would have made this run materially faster or cheaper? Be specific; do not flatter the tooling.'

# --- pre-flight ---------------------------------------------------------------
ver="$(tecs --version)"
echo "== oneshot $n: tecs $ver   game=$game${model:+   model=$model}"
case "$ver" in
    *-dev) ;;
    *) echo "WARNING: not a -dev build; you are testing the installed CLI, not the working tree" >&2 ;;
esac

if [ -e "$project" ]; then
    echo "ERROR: $project already exists; pick another N or remove it" >&2
    exit 1
fi

# A zombie game holding the MCP port poisons the whole run.
squatter="$(lsof -nP -iTCP:19999 -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$squatter" ]; then
    echo "== killing process $squatter holding port 19999"
    kill "$squatter" 2>/dev/null || true
    sleep 2
fi

echo "== scaffolding $project"
tecs new "$project" >/dev/null
grep -q "canonical verification" "$project/.claude/skills/tecs-cli/SKILL.md" \
    || { echo "ERROR: scaffold is stale (no canonical-verification guidance) — rebuild dist" >&2; exit 1; }

mkdir -p "$results"
cp -R "$project/.claude" "$results/scaffold-claude-dir"   # what guidance the agent saw
python3 - "$results/meta.json" "$n" "$game" "$model" "$ver" "$prompt" <<'EOF'
import json, sys, datetime
path, n, game, model, ver, prompt = sys.argv[1:7]
json.dump({"n": int(n), "game": game, "model": model or None, "tecs": ver,
           "prompt": prompt, "started": datetime.datetime.now().isoformat()},
          open(path, "w"), indent=2)
EOF

# --- the run -------------------------------------------------------------------
echo "== launching claude in $project"
echo "   prompt: $prompt"
start_epoch="$(date +%s)"

(
    cd "$project"
    # The raw stream-json is captured verbatim to stream.jsonl via tee while a
    # side formatter pretty-prints live progress (tool calls, agent text, tool
    # errors) to the terminal, so the run can be watched while it executes.
    # The final summary object is extracted into result.json afterwards.
    claude -p "$prompt" \
        ${model_args[@]+"${model_args[@]}"} \
        --output-format stream-json --verbose \
        --dangerously-skip-permissions \
        2> "$results/stderr.log" \
        | tee "$results/stream.jsonl" \
        | python3 -u "$root/scripts/oneshot-stream-fmt.py"
) || echo "WARNING: claude exited non-zero (see $results/stderr.log)" >&2

wall=$(( $(date +%s) - start_epoch ))
# The last stream event is the result summary; that's what result.json held before.
python3 -c "
import json, sys
last = None
for ln in open('$results/stream.jsonl'):
    try: e = json.loads(ln)
    except Exception: continue
    if e.get('type') == 'result': last = e
json.dump(last or {}, open('$results/result.json', 'w'))
"

# --- stats ----------------------------------------------------------------------
python3 - "$results/result.json" "$wall" <<'EOF'
import json, sys
path, wall = sys.argv[1], int(sys.argv[2])
try:
    r = json.load(open(path))
except Exception as e:
    print(f"could not parse result.json: {e}"); sys.exit(0)
u = r.get("usage", {})
total = sum(u.get(k, 0) for k in
            ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
print(f"== duration: {r.get('duration_ms', 0)/1000:.0f}s reported / {wall}s wall "
      f"({wall//60}m{wall%60:02d}s)")
print(f"== tokens:   in={u.get('input_tokens')} out={u.get('output_tokens')} "
      f"cache_read={u.get('cache_read_input_tokens')} cache_write={u.get('cache_creation_input_tokens')} "
      f"total={total}")
print(f"== turns:    {r.get('num_turns')}   cost: ${r.get('total_cost_usd', 0):.2f}")
print(f"== session:  {r.get('session_id')}")
open(path.replace("result.json", "session_id"), "w").write(r.get("session_id", ""))
EOF

session_id="$(cat "$results/session_id" 2>/dev/null || true)"

# --- debrief ----------------------------------------------------------------------
if [ -n "$session_id" ]; then
    echo "== requesting debrief"
    (
        cd "$project"
        claude -p --resume "$session_id" ${model_args[@]+"${model_args[@]}"} "$debrief_prompt" \
            --dangerously-skip-permissions \
            > "$results/debrief.txt" 2>> "$results/stderr.log"
    ) || echo "WARNING: debrief failed" >&2

    # Copy the full transcript for forensics. Project paths are munged with
    # '-' in Claude Code's storage layout.
    munged="$(cd "$project" && pwd -P | tr '/' '-')"
    transcript="$HOME/.claude/projects/$munged/$session_id.jsonl"
    [ -f "$transcript" ] && cp "$transcript" "$results/transcript.jsonl" \
        || echo "NOTE: transcript not found at $transcript" >&2
fi

# --- cleanup: leftover game processes from this run --------------------------------
leftover="$(lsof -nP -iTCP:19999 -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$leftover" ]; then
    echo "== killing leftover game process $leftover"
    kill "$leftover" 2>/dev/null || true
    sleep 1
fi

# --- autograde: objective liveness, independent of what the agent claimed ----------
# Boots the game the agent left behind and probes ground truth: build passes,
# MCP answers, entities exist, named state is present, and the game survives
# three seconds of live play without crashing. Catches "the debrief says
# verified but the game barely runs".
echo "== autograde"
grade="build=FAIL"
if (cd "$project" && tecs build >/dev/null 2>&1); then
    grade="build=ok"
    (cd "$project" && tecs run >/dev/null 2>&1 &)
    booted=""
    for _ in $(seq 1 30); do
        if (cd "$project" && tecs call ping '{}' >/dev/null 2>&1); then booted=1; break; fi
        sleep 1
    done
    if [ -z "$booted" ]; then
        grade="$grade boot=FAIL"
    else
        grade="$grade boot=ok $(cd "$project" && python3 - <<'EOF'
import json, subprocess, time

def call(tool, args="{}"):
    try:
        out = subprocess.run(["tecs", "call", tool, args],
                             capture_output=True, text=True, timeout=20).stdout
        return (json.loads(out) or {}).get("result") or {}
    except Exception:
        return {}

count_code = ("local t = require(\"tecs\") "
              "return world:query({include = {t.builtins.Transform}}):count()")

def entities():
    vals = call("run_lua", json.dumps({"code": count_code})).get("values") or [0]
    return vals[0]

n = entities()
# Game-authored named state only: skip framework keys and anonymous tables.
res = call("cmd_resources").get("resources") or []
named = sum(1 for e in res
            if not str(e.get("key", "")).startswith(("table: ", "tecs2d.", "tecs.")))
time.sleep(3)
ping = call("ping")
alive = ping.get("running") is True and not ping.get("crashed")
print(f"entities={n} named_state={named} "
      f"alive3s={'ok' if alive else 'CRASHED'} entities_after={entities()}")
EOF
)"
    fi
    squat="$(lsof -nP -iTCP:19999 -sTCP:LISTEN -t 2>/dev/null || true)"
    [ -n "$squat" ] && kill "$squat" 2>/dev/null || true
fi
echo "== autograde: $grade" | tee "$results/autograde.txt"

echo "== done. artifacts in $results/"
ls "$results"

}

main "$@"
