#!/usr/bin/env python3
# Live formatter for `claude --output-format stream-json`: reads the event
# stream on stdin and prints a compact human progress log (tool calls, agent
# text, tool errors) so a oneshot run can be watched while it executes. The
# raw stream is preserved separately via tee; this output is display-only.
import json
import sys
import time

START = time.time()


def stamp() -> str:
    t = int(time.time() - START)
    return f"[{t // 60}:{t % 60:02d}]"


def emit(line: str) -> None:
    print(line, flush=True)


def compact(value, limit: int) -> str:
    text = json.dumps(value) if not isinstance(value, str) else value
    text = text.replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def emit_codex_item(item) -> None:
    itype = item.get("type")
    if itype == "agent_message":
        emit(f"{stamp()} ✎ {compact(item.get('text', ''), 400)}")
    elif itype == "reasoning":
        pass
    elif itype == "command_execution":
        emit(f"{stamp()} → $ {compact(item.get('command', ''), 120)}")
    elif itype == "mcp_tool_call":
        name = item.get("tool") or item.get("name") or "?"
        emit(f"{stamp()} → {name} {compact(item.get('arguments', {}), 120)}")
    elif itype == "error":
        emit(f"{stamp()} ✗ {compact(item, 200)}")
    else:
        emit(f"{stamp()} → {itype} {compact(item, 120)}")


for raw in sys.stdin:
    try:
        event = json.loads(raw)
    except Exception:
        continue
    kind = event.get("type")
    # Codex `exec --json` events (thread.started / item.completed /
    # turn.completed); Claude Code stream-json events handled below.
    if kind == "item.completed":
        emit_codex_item(event.get("item", {}))
        continue
    if kind == "turn.completed":
        u = event.get("usage", {})
        emit(f"{stamp()} ■ turn done (in={u.get('input_tokens')} out={u.get('output_tokens')})")
        continue
    if kind == "thread.started":
        emit(f"{stamp()} thread {event.get('thread_id')}")
        continue
    if kind == "error":
        emit(f"{stamp()} ✗ {compact(event, 200)}")
        continue
    if kind == "assistant":
        for block in event.get("message", {}).get("content", []):
            btype = block.get("type")
            if btype == "tool_use":
                emit(f"{stamp()} → {block.get('name')} {compact(block.get('input', {}), 120)}")
            elif btype == "text" and block.get("text", "").strip():
                emit(f"{stamp()} ✎ {compact(block['text'].strip(), 400)}")
    elif kind == "user":
        content = event.get("message", {}).get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result" \
                        and block.get("is_error"):
                    emit(f"{stamp()} ✗ {compact(block.get('content'), 200)}")
    elif kind == "result":
        emit(f"{stamp()} ■ agent finished")
