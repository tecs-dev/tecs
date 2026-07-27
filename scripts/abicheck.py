#!/usr/bin/env python3
"""Verify that generated cdefs match the real C ABI.

A hand-written or mis-generated cdef does not fail to link. It silently
reinterprets memory, and the symptom surfaces later as corrupted data far from
the cause. This compares LuaJIT's view of every generated struct against the C
compiler's: total size, alignment, and the offset of each field.

Run via `make abi-check`.
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

LIBRARIES = [
    {"name": "sdl3", "headers": ["SDL3/SDL.h"], "module": "sdl3"},
    # `requires` names bindings that must be declared first. SDL_mixer's
    # header is written against SDL's types, so its cdef does not parse alone.
    {"name": "sdl3mixer", "headers": ["SDL3_mixer/SDL_mixer.h"], "module": "sdl3-mixer", "requires": ["sdl3"]},
    {"name": "box2d", "headers": ["box2d/box2d.h"], "module": None},
    {"name": "shaderc", "headers": ["shaderc/shaderc.h"], "module": "shaderc"},
]

# `typedef struct Name {` opening a record body.
RECORD_START_RE = re.compile(r"typedef\s+(struct|union)\s+(\w+)?\s*\{")
# The typedef name that closes it: `} Name;`
RECORD_END_RE = re.compile(r"\s*(\w+)\s*;")
# A field line: strip arrays and pointers down to the name.
FIELD_RE = re.compile(r"(\w+)\s*(?:\[[^\]]*\])*\s*;\s*$")


def includeDirs(module):
    """Include directories for a dependency, from pkg-config where it has one.

    Asking pkg-config rather than a package manager keeps this working on a
    machine that has no Homebrew, which is every CI runner and every
    cross-compilation host.
    """
    if module:
        try:
            out = subprocess.run(["pkg-config", "--cflags-only-I", module], capture_output=True, text=True, check=True)
            dirs = [flag[2:] for flag in out.stdout.split() if flag.startswith("-I")]
            if dirs:
                return dirs
        except Exception:
            pass

    # Box2D ships no pkg-config file, and a fallback keeps the common case
    # working without configuration.
    for candidate in ("/opt/homebrew/include", "/usr/local/include", "/usr/include"):
        if Path(candidate).is_dir():
            return [candidate]
    return []


def generatedDir() -> Path:
    """Where the bindings were written.

    CMake writes under its own build directory, so the location is passed in
    rather than assumed.
    """
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    for candidate in (REPO / "build" / "tecs" / "ffi", REPO / "out" / "lua" / "tecs" / "ffi"):
        if candidate.is_dir():
            return candidate
    sys.exit("cannot find generated bindings; pass their directory")


GEN = None


def readCdef(name: str) -> str:
    path = GEN / f"{name}cdef.lua"
    if not path.exists():
        sys.exit(f"missing {path}; run `make cdef` first")
    text = path.read_text()
    start = text.index("[==========[") + len("[==========[")
    end = text.rindex("]==========]")
    return text[start:end]


def parseRecords(cdef: str):
    """Yield (typedefName, kind, [fieldNames]) for every named record.

    Brace matching rather than a regex: SDL structs nest anonymous unions, and
    a non-greedy body match closes on the inner brace and mistakes a member
    name for the record name.
    """
    records = []
    position = 0
    while True:
        start = RECORD_START_RE.search(cdef, position)
        if not start:
            return records

        open_ = cdef.index("{", start.start())
        depth = 0
        i = open_
        while i < len(cdef):
            if cdef[i] == "{":
                depth += 1
            elif cdef[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(cdef):
            return records

        body = cdef[open_ + 1 : i]
        end = RECORD_END_RE.match(cdef, i + 1)
        position = i + 1
        if not end:
            continue
        position = end.end()

        fields = []
        depth = 0
        for line in body.splitlines():
            stripped = line.strip()
            opens = stripped.count("{")
            closes = stripped.count("}")
            # Only top-level members are addressable by a bare offsetof path;
            # members of nested anonymous records are reachable but their
            # names are ambiguous, so they are skipped.
            if depth == 0 and opens == 0 and stripped.endswith(";"):
                m = FIELD_RE.search(stripped)
                if m:
                    fields.append(m.group(1))
            depth += opens - closes

        records.append((end.group(1), start.group(1), fields))


def cReport(headers, includeDirs, records):
    """Ask the C compiler for the authoritative layout."""
    includes = "\n".join(f"#include <{h}>" for h in headers)
    lines = []
    for name, _kind, fields in records:
        lines.append(
            f'    printf("{{\\"name\\":\\"{name}\\",\\"size\\":%zu,\\"align\\":%zu,\\"fields\\":{{",'
            f" sizeof({name}), _Alignof({name}));"
        )
        for i, field in enumerate(fields):
            comma = "" if i == 0 else ","
            lines.append(f'    printf("{comma}\\"{field}\\":%zu", offsetof({name}, {field}));')
        lines.append('    printf("}}\\n");')

    program = (
        f"{includes}\n#include <stdio.h>\n#include <stddef.h>\n"
        "int main(void) {\n" + "\n".join(lines) + "\n    return 0;\n}\n"
    )

    with tempfile.TemporaryDirectory() as d:
        csrc = Path(d) / "abi.c"
        exe = Path(d) / "abi"
        csrc.write_text(program)
        cmd = ["cc", "-std=c11", "-w", "-o", str(exe), str(csrc)]
        for inc in includeDirs:
            cmd += ["-I", inc]
        build = subprocess.run(cmd, capture_output=True, text=True)
        if build.returncode != 0:
            sys.stderr.write(build.stderr[:3000])
            sys.exit("abi probe failed to compile")
        run = subprocess.run([str(exe)], capture_output=True, text=True)

    report = {}
    for line in run.stdout.splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        report[entry["name"]] = entry
    return report


def luaReport(name: str, records, requires=()):
    """Ask LuaJIT for its view of the same records."""
    wanted = [{"name": n, "fields": f} for n, _k, f in records]
    declare = "\n".join(f'ffi.cdef(require("tecs.ffi.{dep}cdef"))' for dep in requires)
    script = """
local ffi = require("ffi")
local json = ...
package.path = "%s/?.lua;%s/?/init.lua;" .. package.path
%s
local cdefSource = require("tecs.ffi.%scdef")
ffi.cdef(cdefSource)
local out = {}
for line in io.lines(json) do
    local name = line:match('^([^\\t]+)')
    local fields = {}
    for f in line:gmatch('\\t([^\\t]+)') do fields[#fields+1] = f end
    local ok, size = pcall(ffi.sizeof, name)
    if ok and size then
        local parts = { name, tostring(size), tostring(ffi.alignof(name)) }
        for _, f in ipairs(fields) do
            local ok2, off = pcall(ffi.offsetof, name, f)
            if ok2 and off then parts[#parts+1] = f .. "=" .. tostring(off) end
        end
        out[#out+1] = table.concat(parts, "\\t")
    end
end
print(table.concat(out, "\\n"))
""" % (GEN.parent.parent, GEN.parent.parent, declare, name)

    with tempfile.TemporaryDirectory() as d:
        listing = Path(d) / "records.txt"
        listing.write_text("\n".join("\t".join([r["name"]] + r["fields"]) for r in wanted) + "\n")
        script_path = Path(d) / "probe.lua"
        script_path.write_text(script)
        run = subprocess.run(["luajit", str(script_path), str(listing)], capture_output=True, text=True, cwd=REPO)
    if run.returncode != 0:
        sys.stderr.write(run.stderr[:3000])
        sys.exit("luajit abi probe failed")

    report = {}
    for line in run.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        entry = {"size": int(parts[1]), "align": int(parts[2]), "fields": {}}
        for item in parts[3:]:
            field, _, offset = item.partition("=")
            entry["fields"][field] = int(offset)
        report[parts[0]] = entry
    return report


def main():
    global GEN
    GEN = generatedDir()
    totalChecked = 0
    mismatches = []

    for lib in LIBRARIES:
        name = lib["name"]
        includes = includeDirs(lib["module"])

        cdef = readCdef(name)
        records = parseRecords(cdef)
        if not records:
            print(f"{name}: no records found")
            continue

        fromC = cReport(lib["headers"], includes, records)
        fromLua = luaReport(name, records, lib.get("requires", ()))

        checked = 0
        for recordName, _kind, fields in records:
            c = fromC.get(recordName)
            lua = fromLua.get(recordName)
            if c is None or lua is None:
                continue
            checked += 1
            if c["size"] != lua["size"]:
                mismatches.append(f"{name}.{recordName}: sizeof C={c['size']} lua={lua['size']}")
            if c["align"] != lua["align"]:
                mismatches.append(f"{name}.{recordName}: alignof C={c['align']} lua={lua['align']}")
            for field in fields:
                cOffset = c["fields"].get(field)
                luaOffset = lua["fields"].get(field)
                if cOffset is None or luaOffset is None:
                    continue
                if cOffset != luaOffset:
                    mismatches.append(f"{name}.{recordName}.{field}: offset C={cOffset} lua={luaOffset}")

        totalChecked += checked
        print(f"{name}: {checked} records verified")

    if mismatches:
        print(f"\n{len(mismatches)} ABI MISMATCHES:")
        for m in mismatches[:50]:
            print(f"  {m}")
        sys.exit(1)

    print(f"\nABI OK: {totalChecked} records match the C compiler")


if __name__ == "__main__":
    main()
