#!/usr/bin/env bash
# Orchestrate one unattended "one-shot" eval: scaffold a fresh game project
# with the working-tree CLI (dist/tecs), launch a headless Claude session in
# it with the standard prompt, time it, capture token usage, ask the agent
# for a debrief, and collect the transcript — everything lands in
# /tmp/oneshot<N>-results/ for review.
#
# Usage:
#   scripts/oneshot.sh [N] [prompt...]
#     N       run number (default: next free /tmp/oneshot<N>)
#     prompt  override the default prompt (rarely needed)
#
# The nested Claude runs with --dangerously-skip-permissions so the run is
# fully unattended; only launch this against scratch projects.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/dist:$PATH"

# --- resolve run number and paths -------------------------------------------
n="${1:-}"
if [ -z "$n" ]; then
    n=1
    while [ -e "/tmp/oneshot$n" ]; do n=$((n + 1)); done
else
    shift || true
fi
prompt="${*:-oneshot create a nibbles game with tecs and tecs2d}"

project="/tmp/oneshot$n"
results="/tmp/oneshot$n-results"

debrief_prompt='Debrief this session honestly: (1) Did the tecs MCP bridge tools work the whole time — and did you actually use them? (2) Where did the time and tokens go; what was wasted? (3) What did you try that failed, and why? (4) What one or two changes to the project guidance or tecs tooling would have made this run materially faster or cheaper? Be specific; do not flatter the tooling.'

# --- pre-flight ---------------------------------------------------------------
ver="$(tecs --version)"
echo "== oneshot $n: tecs $ver"
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

# --- the run -------------------------------------------------------------------
echo "== launching claude in $project"
echo "   prompt: $prompt"
start_epoch="$(date +%s)"

(
    cd "$project"
    claude -p "$prompt" \
        --output-format json \
        --dangerously-skip-permissions \
        > "$results/result.json" 2> "$results/stderr.log"
) || echo "WARNING: claude exited non-zero (see $results/stderr.log)" >&2

wall=$(( $(date +%s) - start_epoch ))

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
        claude -p --resume "$session_id" "$debrief_prompt" \
            --dangerously-skip-permissions \
            > "$results/debrief.txt" 2>> "$results/stderr.log"
    ) || echo "WARNING: debrief failed" >&2

    # Copy the full transcript for forensics. Project paths are munged with
    # '-' in Claude Code's storage layout.
    munged="$(cd "$project" && pwd | tr '/' '-')"
    transcript="$HOME/.claude/projects/$munged/$session_id.jsonl"
    [ -f "$transcript" ] && cp "$transcript" "$results/transcript.jsonl" \
        || echo "NOTE: transcript not found at $transcript" >&2
fi

# --- cleanup: leftover game processes from this run --------------------------------
leftover="$(lsof -nP -iTCP:19999 -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$leftover" ]; then
    echo "== killing leftover game process $leftover"
    kill "$leftover" 2>/dev/null || true
fi

echo "== done. artifacts in $results/"
ls "$results"
