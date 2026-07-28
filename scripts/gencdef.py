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
DROP_LINE_RE = re.compile(r"^\s*(_Static_assert|static_assert|#pragma|extern\s+\"C\"|\})?\s*$")

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


LINE_MARKER_RE = re.compile(r'^#\s+\d+\s+"([^"]*)"')


def selectByFile(preprocessed: str, keeps, wanted: bool = True) -> str:
    """Keep text from headers whose path contains one of `keeps`.

    With `wanted` false this returns the complement instead, which is where a
    type the kept headers use but do not declare is recovered from.
    """
    kept = []
    active = False
    for line in preprocessed.splitlines():
        m = LINE_MARKER_RE.match(line)
        if m:
            active = any(k in m.group(1) for k in keeps) == wanted
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


IDENTIFIER_RE = re.compile(r"\b[A-Za-z_]\w*\b")
TAGGED_RE = re.compile(r"\b(struct|union|enum)\s+([A-Za-z_]\w*)")


def statements(text: str):
    """Yields top-level statements, so a record body's semicolons are ignored."""
    depth = 0
    current = []
    for character in text:
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        elif character == ";" and depth == 0:
            yield "".join(current).strip() + ";"
            current = []
            continue
        current.append(character)


def declaredNames(statement: str) -> set:
    """The type names a statement introduces.

    A tagged record is named by its tag (`struct sockaddr`) and a typedef by
    the identifier it ends with, which is the last one outside the record body
    and outside any parameter list.
    """
    names = set()
    body = statement
    open_ = body.find("{")
    if open_ != -1:
        close = body.rfind("}")
        head, tail = body[:open_], body[close + 1 :]
        m = TAGGED_RE.search(head)
        if m:
            names.add(f"{m.group(1)} {m.group(2)}")
        body = head + tail
    elif not body.lstrip().startswith("typedef"):
        m = TAGGED_RE.search(body)
        if m:
            names.add(f"{m.group(1)} {m.group(2)}")

    if statement.lstrip().startswith("typedef"):
        # `typedef void (*sig_t)(int);` names the identifier inside the
        # parentheses; everything else names the last identifier before the
        # semicolon, with any array bounds already behind it.
        pointer = re.search(r"\(\s*\*\s*([A-Za-z_]\w*)\s*\)", body)
        if pointer:
            names.add(pointer.group(1))
        else:
            found = IDENTIFIER_RE.findall(body.split("(")[0])
            if found:
                names.add(found[-1])
    return names


def referencedNames(statement: str) -> set:
    """Every type name a statement could depend on."""
    names = set(IDENTIFIER_RE.findall(statement))
    for kind, tag in TAGGED_RE.findall(statement):
        names.add(f"{kind} {tag}")
    return names


def recoverTypes(rejected: str, alreadyDeclared: set, needed) -> str:
    """Declarations for types the kept headers use and do not declare.

    curl's headers are written against the platform's, so a binding built from
    them alone refers to `time_t` and `struct sockaddr` without ever declaring
    either, and LuaJIT rejects the result. Those declarations are recovered
    from the same preprocessor output rather than written by hand here: a
    hand-written one is an ABI claim nothing checks, and the layout it claims
    differs between the targets this tree builds for.

    Dependencies are followed, since a recovered record names types of its own,
    and the result keeps its original order, which is the order C needs.
    """
    ordered = [s for s in statements(rejected) if s.strip(" ;")]
    provides = {}
    for index, statement in enumerate(ordered):
        for name in declaredNames(statement):
            if name not in provides and name not in alreadyDeclared:
                provides[name] = index

    chosen = set()
    pending = list(needed)
    while pending:
        name = pending.pop()
        index = provides.get(name)
        if index is None or index in chosen:
            continue
        chosen.add(index)
        pending.extend(referencedNames(ordered[index]) - alreadyDeclared)

    if not chosen:
        return ""
    return "\n".join(ordered[index] for index in sorted(chosen)) + "\n"


# Stem of the throwaway program the constants are recovered from. Distinctive
# on purpose: a macro reaching `__FILE__` evaluates to this program's own name,
# and that value is recognized by looking for this.
PROBE_NAME = "tecsconsts"


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
    """Recover constants by letting the C compiler evaluate them.

    Constants like SDL_WINDOW_RESIZABLE expand through helper macros
    (`SDL_UINT64_C(0x20)`) and shift expressions, so pattern-matching the
    preprocessor output misses most of them and silently produces a partial
    table. Compiling a program that prints each value is exact.

    A macro's value is not always a number. SDL names every hint and every
    property with a string macro, and those are the argument the API that reads
    them takes, so they belong in the table as much as an enum value does. Which
    kind a macro is comes from `_Generic`, asked of the compiler rather than
    guessed from the macro body, because a string can arrive through another
    macro. The `+ 0` is what makes a string literal answer: its type is an
    array, and `_Generic` inspects the type it is given without decaying it.

    Printing one kind as another is the trap this exists to avoid, and it does
    not announce itself. Casting a `const char *` or a function to an integer is
    legal C, so a macro naming a property or aliasing `memcpy` compiles happily
    and yields an address from this process: a plausible-looking number that
    means nothing anywhere else. So a macro is emitted only when it is a number
    or a string, and anything else, a pointer or a function among them, is not a
    constant and is left out.

    Macros that are not expressions at all fail to compile; their lines are
    removed and the program is retried until it builds.
    """
    names = macroNames(headers, includeDirs, defines, prefixes)
    if not names:
        return {}

    limitFlags = errorLimitFlags()
    # Twice, from a differently named function at a different line. A macro
    # reaching `__LINE__` or `__func__` describes where it was written rather
    # than anything a caller could use, and the only way to tell one of those
    # from a constant is that its value moves when the place it is written
    # does. Keeping what both runs agree on is what leaves them out.
    first = evaluateMacros(names, headers, includeDirs, defines, limitFlags, "tecsFirst", 0)
    second = evaluateMacros(names, headers, includeDirs, defines, limitFlags, "tecsSecond", 3)
    return {name: value for name, value in first.items() if second.get(name) == value}


def evaluateMacros(names, headers, includeDirs, defines, limitFlags, funcName, pad):
    """Compile and run one program that prints every macro it can."""
    # `(intptr_t)` sits in the middle of the text cast so that a macro whose
    # value is floating point still compiles: a double converts to an integer
    # and an integer converts to a pointer, where a double to a pointer is an
    # error that would drop the macro rather than classify it.
    prologue = (
        [f"#include <{h}>" for h in headers]
        + [
            "#include <stdio.h>",
            "#include <stdint.h>",
            "#define TECS_KIND(x) _Generic((x) + 0,"
            " char *: 2, const char *: 2,"
            " _Bool: 1, short: 1, unsigned short: 1, int: 1, unsigned int: 1,"
            " long: 1, unsigned long: 1, long long: 1, unsigned long long: 1,"
            " float: 1, double: 1, long double: 1,"
            " default: 0)",
        ]
        + [""] * pad
        + [f"static void {funcName}(void) {{"]
    )
    epilogue = ["}", "int main(void) {", f"    {funcName}();", "    return 0;", "}", ""]
    dropped: set[str] = set()

    for _ in range(40):
        active = [n for n in names if n not in dropped]
        if not active:
            return {}
        body = [
            f'    if (TECS_KIND({n}) == 2) printf("{n}\\tS\\t%s\\n",'
            f" (const char *)(intptr_t)({n}));"
            f" else if (TECS_KIND({n}) == 1)"
            f' printf("{n}\\tI\\t%lld\\n", (long long)({n}));'
            for n in active
        ]
        program = "\n".join(prologue + body + epilogue)
        with tempfile.TemporaryDirectory() as d:
            csrc = Path(d) / f"{PROBE_NAME}.c"
            exe = Path(d) / PROBE_NAME
            csrc.write_text(program)
            cmd = ["cc", "-std=c11", "-w", *limitFlags, "-o", str(exe), str(csrc)]
            for inc in includeDirs:
                cmd += ["-I", inc]
            for dd in defines:
                cmd += ["-D", dd]
            build = subprocess.run(cmd, capture_output=True, text=True)

            if build.returncode != 0:
                bad = set()
                for m in re.finditer(PROBE_NAME + r"\.c:(\d+):", build.stderr):
                    idx = int(m.group(1)) - len(prologue) - 1
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
                parts = line.split("\t", 2)
                if len(parts) != 3:
                    continue
                name, kind, value = parts
                if kind != "S":
                    found[name] = int(value)
                elif PROBE_NAME not in value:
                    found[name] = value
                # A string naming this program is `__FILE__` reached through
                # some macro. Both runs compile a file of the same name, so the
                # agreement test cannot see it and this one does. The compiler
                # reports it as a bare name or as a full path depending on how
                # it was invoked, so the test is on the stem, which is why that
                # stem is distinctive.
            return dict(sorted(found.items()))

    raise SystemExit("constant extraction did not converge")


def errorLimitFlags():
    """Flags that stop the compiler capping how many errors it reports.

    Constants are recovered by compiling every candidate macro at once and
    striking out whatever fails, so a round only makes progress on the macros
    the compiler names. Both compilers stop after twenty errors by default, and
    a bad macro costs more than one, so the default turns a single pass into
    dozens and a large header into a failure to converge.
    """
    for flag in ("-ferror-limit=0", "-fmax-errors=0"):
        with tempfile.TemporaryDirectory() as d:
            probe = Path(d) / "probe.c"
            probe.write_text("int main(void) { return 0; }\n")
            out = subprocess.run(["cc", flag, "-o", str(Path(d) / "probe"), str(probe)], capture_output=True, text=True)
            if out.returncode == 0:
                return [flag]
    return []


def luaValue(value):
    """Render a recovered constant as Lua source."""
    if isinstance(value, int):
        return str(value)
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r")
    return f'"{escaped}"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", action="append", required=True, help="header to include, e.g. SDL3/SDL.h")
    ap.add_argument("--include", action="append", default=[], help="include directory")
    ap.add_argument("--define", action="append", default=[])
    ap.add_argument("--keep", action="append", required=True, help="only keep declarations from paths containing this")
    ap.add_argument(
        "--need",
        action="append",
        default=[],
        help="a type the kept headers use and do not declare, recovered from the ones they include",
    )
    ap.add_argument("--define-prefix", action="append", default=[], help="emit integer #defines with this name prefix")
    ap.add_argument("--defines-out", help="write recovered #define constants here as a Lua table")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.defines_out:
        consts = extractDefines(args.header, args.include, args.define, args.define_prefix)
        dest = Path(args.defines_out)
        dest.parent.mkdir(parents=True, exist_ok=True)
        lines = ["-- Generated by scripts/gencdef.py. Do not edit.", "return {"]
        for name, value in consts.items():
            lines.append(f"    {name} = {luaValue(value)},")
        lines.append("}")
        dest.write_text("\n".join(lines) + "\n")
        print(f"{dest}: {len(consts)} constants")

    pp = preprocess(args.header, args.include, args.define)
    body = clean(selectByFile(pp, args.keep))

    if args.need:
        declared = set()
        for statement in statements(body):
            declared |= declaredNames(statement)
        prelude = recoverTypes(clean(selectByFile(pp, args.keep, wanted=False)), declared, args.need)
        # A name that came back with nothing behind it would leave the binding
        # naming a type it never declares, which LuaJIT rejects at load with a
        # message pointing at the use rather than at the absence.
        available = declared | set(IDENTIFIER_RE.findall(prelude))
        missing = [name for name in args.need if name.split()[-1] not in available]
        if missing:
            raise SystemExit(f"cannot recover declarations for: {', '.join(missing)}")
        body = prelude + body

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
