#!/usr/bin/env python3
"""Check an installed tree for dependencies it does not carry.

A package that resolved a library from the build machine works there and
nowhere else, and the failure appears only once someone else unpacks it. This
inspects the installed binaries for absolute references and search paths that
point outside the package, and for a shader compiler that a release is not
supposed to ship.

Usage: checkpackage.py <install-prefix> [--allow-compiler]
"""

import re
import subprocess
import sys
from pathlib import Path

# Libraries the platform itself provides. Referencing these absolutely is
# correct: they are part of the target, not of the build machine.
SYSTEM_PREFIXES = (
    "/usr/lib/", "/System/Library/", "@rpath/", "@executable_path/",
    "@loader_path/", "/lib/", "/lib64/",
)

# Shader compilation is a development capability. A release consumes packaged
# artifacts instead, and shipping the compiler means the fallback can happen
# silently on a target that was supposed to have none.
COMPILER_NAMES = ("shaderc", "spirvcross", "spirv-cross", "dxcompiler")


def machoReferences(binary: Path):
    """Returns (rpaths, linked libraries) for a Mach-O file."""
    out = subprocess.run(["otool", "-l", str(binary)],
                         capture_output=True, text=True)
    rpaths = re.findall(r"cmd LC_RPATH.*?path ([^\s]+)", out.stdout, re.S)

    linked = subprocess.run(["otool", "-L", str(binary)],
                            capture_output=True, text=True)
    libs = [line.split()[0] for line in linked.stdout.splitlines()[1:]
            if line.strip()]
    return rpaths, libs


def elfReferences(binary: Path):
    out = subprocess.run(["readelf", "-d", str(binary)],
                         capture_output=True, text=True)
    rpaths = re.findall(r"\(R(?:UN)?PATH\).*\[([^\]]+)\]", out.stdout)
    rpaths = [part for entry in rpaths for part in entry.split(":")]
    libs = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", out.stdout)
    return rpaths, libs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    prefix = Path(sys.argv[1]).resolve()
    allowCompiler = "--allow-compiler" in sys.argv

    if not prefix.is_dir():
        sys.exit(f"no such install prefix: {prefix}")

    # A development install links the build machine's libraries on purpose.
    # Reporting that as a failure would train people to ignore this check, so
    # it is stated and passed instead; only a packaged build is held to it.
    info = prefix / "share" / "tecs" / "build-info.txt"
    development = "systemDeps=ON" in info.read_text() if info.exists() else False

    binaries = [p for p in prefix.rglob("*")
                if p.is_file() and (p.suffix in (".dylib", ".so") or
                                    (p.parent.name == "bin"))]
    if not binaries:
        sys.exit(f"no binaries found under {prefix}")

    problems = []
    for binary in binaries:
        rpaths, libs = (machoReferences(binary) if sys.platform == "darwin"
                        else elfReferences(binary))

        for rpath in rpaths:
            if not rpath.startswith(("@executable_path", "@loader_path", "$ORIGIN")):
                problems.append(f"{binary.name}: search path leaves the package: {rpath}")

        for lib in libs:
            if lib.startswith("/") and not lib.startswith(SYSTEM_PREFIXES):
                problems.append(f"{binary.name}: links an absolute path: {lib}")

        if not allowCompiler:
            for name in COMPILER_NAMES:
                if name in binary.name.lower():
                    problems.append(
                        f"{binary.name}: a shader compiler must not ship in a release")

    # A release ships no compiler, so it has to ship the shaders. An install
    # missing its pack opens a window and then fails at the first pipeline,
    # which is a far worse failure than this one.
    packs = list(prefix.rglob("*.tsp"))
    if not packs:
        problems.append("no shader pack (*.tsp): a release ships no compiler, "
                        "so it must ship compiled shaders")
    for pack in packs:
        manifest = pack.with_suffix(pack.suffix + ".txt")
        if not manifest.exists():
            problems.append(f"{pack.name}: no manifest beside it, so what it "
                            "contains cannot be checked")
        else:
            summary = manifest.read_text().splitlines()[1]
            print(f"{pack.relative_to(prefix)}: {summary}")

    print(f"checked {len(binaries)} binaries under {prefix}")

    if development:
        print("development install: system dependencies are expected here")
        if problems:
            print(f"{len(problems)} references to the build machine, "
                  "which a packaged preset would not have:")
            for problem in problems:
                print(f"  {problem}")
        return

    if problems:
        print(f"\n{len(problems)} problems:")
        for problem in problems:
            print(f"  {problem}")
        sys.exit(1)
    print("package is self-contained")


if __name__ == "__main__":
    main()
