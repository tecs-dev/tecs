#!/usr/bin/env python3
"""Generate a LuaJIT ffi.cdef block from C headers.

Runs the system preprocessor over a set of headers, keeps only the
declarations that originate from headers matching --keep, and rewrites the
result into the subset of C that LuaJIT's ffi parser accepts.

Hand-maintained cdefs drift from the installed library's ABI silently, and a
mismatch corrupts memory rather than failing to link. Regenerating from the
real headers is the only way to keep them honest.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Constructs LuaJIT's C parser does not accept. Removed outright.
DROP_TOKENS = [
    "__extension__",
    "__restrict__",
    "__restrict",
    "__inline__",
    "__inline",
    "__signed__",
    "__nonnull",
    "_Noreturn",
    "SDLCALL",
]

# Lines that are entire declarations we never want to forward.
DROP_LINE_RE = re.compile(
    r"^\s*(_Static_assert|static_assert|#pragma|extern\s+\"C\"|\})?\s*$"
)

ATTRIBUTE_RE = re.compile(r"__attribute__\s*\(")
ASM_RE = re.compile(r"__asm(__)?\s*\(")


def stripBalanced(text: str, pattern: re.Pattern) -> str:
    """Remove `name(...)` constructs, matching parentheses properly.

    A regex alone cannot do this: attribute payloads nest parens.
    """
    while True:
        m = pattern.search(text)
        if not m:
            return text
        i = m.end() - 1  # at the opening paren
        depth = 0
        j = i
        while j < len(text):
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if j >= len(text):
            return text[: m.start()]
        text = text[: m.start()] + text[j + 1 :]


def preprocess(headers, includeDirs, defines):
    src = "\n".join(f"#include <{h}>" for h in headers) + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as f:
        f.write(src)
        tmp = f.name
    cmd = ["cc", "-E", "-std=c99"]
    for d in includeDirs:
        cmd += ["-I", d]
    for d in defines:
        cmd += ["-D", d]
    cmd.append(tmp)
    out = subprocess.run(cmd, capture_output=True, text=True)
    Path(tmp).unlink(missing_ok=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit(f"preprocessor failed ({out.returncode})")
    return out.stdout


def selectByFile(preprocessed: str, keep: str) -> str:
    """Keep only text that came from headers whose path contains `keep`."""
    lineMarker = re.compile(r'^#\s+\d+\s+"([^"]*)"')
    kept = []
    active = False
    for line in preprocessed.splitlines():
        m = lineMarker.match(line)
        if m:
            active = keep in m.group(1)
            continue
        if active:
            kept.append(line)
    return "\n".join(kept)


def clean(text: str) -> str:
    text = stripBalanced(text, ATTRIBUTE_RE)
    text = stripBalanced(text, ASM_RE)
    for tok in DROP_TOKENS:
        text = re.sub(rf"\b{re.escape(tok)}\b", " ", text)

    # LuaJIT has no use for these and chokes on some of them.
    text = re.sub(r"\bextern\s+\"C\"\s*\{", "", text)

    lines = []
    skipDepth = 0
    skipping = False
    for line in text.splitlines():
        stripped = line.strip()

        # `static const b2Vec2 b2Vec2_zero = {0,0};` and `static inline`
        # helpers are definitions, not declarations. cdef rejects both, and
        # they carry no ABI information the bindings need.
        if not skipping and re.match(r"^\s*static\b", line):
            skipping = True
            skipDepth = 0
        if skipping:
            skipDepth += stripped.count("{") - stripped.count("}")
            if skipDepth <= 0 and (stripped.endswith(";") or stripped.endswith("}")):
                skipping = False
            continue

        if DROP_LINE_RE.match(line) and not stripped.startswith("}"):
            continue
        if re.match(r"^\s*(_Static_assert|static_assert)\b", line):
            continue
        if stripped.startswith("#"):
            continue
        lines.append(line.rstrip())

    text = "\n".join(lines)
    # Collapse the runs of blank lines the preprocessor leaves behind.
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


# Object-like macro, i.e. no parameter list. Function-like macros cannot be
# evaluated as constants and are skipped.
OBJECT_MACRO_RE = re.compile(r"^#define\s+([A-Za-z_]\w*)\s+(.*)$")


def macroNames(headers, includeDirs, defines, prefixes):
    """List candidate object-like macro names via `cc -E -dM`."""
    src = "\n".join(f"#include <{h}>" for h in headers) + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as f:
        f.write(src)
        tmp = f.name
    cmd = ["cc", "-E", "-dM", "-std=c99"]
    for d in includeDirs:
        cmd += ["-I", d]
    for d in defines:
        cmd += ["-D", d]
    cmd.append(tmp)
    out = subprocess.run(cmd, capture_output=True, text=True)
    Path(tmp).unlink(missing_ok=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit("preprocessor failed while listing macros")

    names = []
    for line in out.stdout.splitlines():
        m = OBJECT_MACRO_RE.match(line.strip())
        if not m:
            continue
        name, body = m.group(1), m.group(2)
        if prefixes and not any(name.startswith(p) for p in prefixes):
            continue
        if not body.strip():
            continue
        names.append(name)
    return sorted(set(names))


def extractDefines(headers, includeDirs, defines, prefixes):
    """Recover integer constants by letting the C compiler evaluate them.

    Constants like SDL_WINDOW_RESIZABLE expand through helper macros
    (`SDL_UINT64_C(0x20)`) and shift expressions, so pattern-matching the
    preprocessor output misses most of them and silently produces a partial
    table. Compiling a program that prints each value is exact.

    Macros that are not integer constants fail to compile; their lines are
    removed and the program is retried until it builds.
    """
    names = macroNames(headers, includeDirs, defines, prefixes)
    if not names:
        return {}

    includes = "\n".join(f"#include <{h}>" for h in headers)
    dropped: set[str] = set()

    for _ in range(40):
        active = [n for n in names if n not in dropped]
        if not active:
            return {}
        body = "\n".join(
            f'    printf("{n}=%lld\\n", (long long)({n}));' for n in active
        )
        program = (
            f"{includes}\n#include <stdio.h>\n"
            f"int main(void) {{\n{body}\n    return 0;\n}}\n"
        )
        with tempfile.TemporaryDirectory() as d:
            csrc = Path(d) / "consts.c"
            exe = Path(d) / "consts"
            csrc.write_text(program)
            cmd = ["cc", "-std=c99", "-w", "-o", str(exe), str(csrc)]
            for inc in includeDirs:
                cmd += ["-I", inc]
            for dd in defines:
                cmd += ["-D", dd]
            build = subprocess.run(cmd, capture_output=True, text=True)

            if build.returncode != 0:
                # Line 1-indexed; the printf block starts after includes + 2.
                offset = len(includes.splitlines()) + 2
                bad = set()
                for m in re.finditer(r"consts\.c:(\d+):", build.stderr):
                    idx = int(m.group(1)) - offset - 1
                    if 0 <= idx < len(active):
                        bad.add(active[idx])
                if not bad:
                    sys.stderr.write(build.stderr[:2000])
                    raise SystemExit("cannot evaluate constants")
                dropped |= bad
                continue

            run = subprocess.run([str(exe)], capture_output=True, text=True)
            found = {}
            for line in run.stdout.splitlines():
                if "=" not in line:
                    continue
                name, _, value = line.partition("=")
                found[name] = int(value)
            return dict(sorted(found.items()))

    raise SystemExit("constant extraction did not converge")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", action="append", required=True,
                    help="header to include, e.g. SDL3/SDL.h")
    ap.add_argument("--include", action="append", default=[],
                    help="include directory")
    ap.add_argument("--define", action="append", default=[])
    ap.add_argument("--keep", required=True,
                    help="only keep declarations from paths containing this")
    ap.add_argument("--define-prefix", action="append", default=[],
                    help="emit integer #defines with this name prefix")
    ap.add_argument("--defines-out",
                    help="write recovered #define constants here as a Lua table")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.defines_out:
        consts = extractDefines(args.header, args.include, args.define,
                                args.define_prefix)
        dest = Path(args.defines_out)
        dest.parent.mkdir(parents=True, exist_ok=True)
        lines = ["-- Generated by scripts/gencdef.py. Do not edit.", "return {"]
        for name, value in consts.items():
            lines.append(f"    {name} = {value},")
        lines.append("}")
        dest.write_text("\n".join(lines) + "\n")
        print(f"{dest}: {len(consts)} constants")

    pp = preprocess(args.header, args.include, args.define)
    body = clean(selectByFile(pp, args.keep))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.suffix == ".lua":
        # Long-bracket level chosen to survive any ]] in the source.
        out.write_text(
            "-- Generated by scripts/gencdef.py. Do not edit.\n"
            f"-- headers: {' '.join(args.header)}\n"
            "return [==========[\n" + body + "]==========]\n"
        )
    else:
        out.write_text(body)
    print(f"{out}: {len(body.splitlines())} lines")


if __name__ == "__main__":
    main()
