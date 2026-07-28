#!/usr/bin/env python3
"""Check an installed tree for dependencies it does not carry.

A package that resolved a library from the build machine works there and
nowhere else, and the failure appears only once someone else unpacks it. This
inspects the installed binaries for absolute references and search paths that
point outside the package, and for a shader compiler that a release is not
supposed to ship.

Type information is checked the same way and for the same reason. A game runs
its own `tl check`, and it reaches the engine's types through the installed
Teal sources; if those are absent or incomplete, the failure lands on whoever
unpacked the package, not on whoever built it. So a file using the `tecs`
global is type-checked here against the package.

The license position is checked here too, because this is the only place that
sees what a build actually linked. Every library an installed binary references
has to be one somebody declared, with a license and a reason beside it, and the
notices have to be installed alongside the binaries they describe. Neither of
those reads a license out of a binary, which is not something a binary carries;
`spec/licenses_spec.lua` holds the configure-time half of the same rule.

The one thing the package is not asked to carry is the declarations for LuaJIT
itself and for cjson. Those belong to the `luajit-tl-type` rock and to the
JSON library, not to tecs, and any Teal project on LuaJIT installs them
already. `--teal-types` says where to find them; without it the type check is
reported as not run rather than failed.

Usage: checkpackage.py <install-prefix> [--allow-compiler] [--teal-types <dir>]
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Libraries the platform itself provides. Referencing these absolutely is
# correct: they are part of the target, not of the build machine.
SYSTEM_PREFIXES = (
    "/usr/lib/",
    "/System/Library/",
    "@rpath/",
    "@executable_path/",
    "@loader_path/",
    "/lib/",
    "/lib64/",
)

# Shader compilation is a development capability. A release consumes packaged
# artifacts instead, and shipping the compiler means the fallback can happen
# silently on a target that was supposed to have none.
COMPILER_NAMES = ("shaderc", "spirvcross", "spirv-cross", "dxcompiler")

# What a package carries the notices for. Nothing here reads a license out of a
# binary, because nothing can; this holds the libraries a package links against
# a list somebody wrote down, with the license and the reason beside each. Its
# whole value is that a library nobody has thought about fails the check, so the
# thinking happens before the package ships rather than after.
#
# The rule it exists to keep is "no LGPL, ever". `spec/licenses_spec.lua` holds
# the configure-time half of that, which is the options in `cmake/Pinned.cmake`
# that would fetch an LGPL codec. This is the link-time half: a library that
# arrived some other way still has to be named.
#
# Matched against a normalized stem, so `libluajit-5.1.2.dylib`,
# `libluajit.so.2` and `libluajit-5.1.dylib` are all `luajit`.
LINKED_LIBRARIES = (
    (r"tecs\w*", "MIT OR Apache-2.0", "the engine's own"),
    (r"spirvcrossc", "Apache-2.0 OR MIT", "the shared object the FFI needs over SPIRV-Cross's archives"),
    (r"cjson", "MIT", "lua-cjson, vendored under vendor/cjson"),
    (r"SDL3(_image|_mixer|_net)?", "Zlib", "SDL and its three satellites"),
    (r"luajit", "MIT", "the VM, carrying PUC-Rio Lua's own notice inside it"),
    (r"box2d", "MIT", "the physics solver"),
    (r"shaderc(_shared)?", "Apache-2.0", "a development build's shader compiler; a release links none"),
    (r"png\d*", "libpng-2.0", "PNG decoding under SDL3_image"),
    (r"z", "Zlib", "the deflate libpng reads through"),
    (r"curl", "curl", "HTTP and HTTPS"),
    (r"(mbedtls|mbedx509|tfpsacrypto)", "Apache-2.0", "Mbed TLS, curl's TLS backend, with Apache-2.0 elected"),
    (r"(ogg|opus|opusfile)", "BSD-3-Clause", "SDL_mixer's Opus decoder and its container"),
    (r"wavpack", "BSD-3-Clause", "SDL_mixer's WavPack decoder"),
)

# The notices travel with the binaries they describe. A package that carries the
# code and not the notice is the one license failure this engine is capable of
# committing on its own, and it is invisible until someone else audits a
# release, so it is checked on every install rather than only on a packaged one.
REQUIRED_NOTICES = (
    "share/tecs/THIRD_PARTY_NOTICES.md",
    "share/tecs/LICENSE-MIT",
    "share/tecs/LICENSE-APACHE",
)


# Enough of the surface to prove the type information is whole: the ECS half,
# the engine half reached as a value, and the engine half reached as a type.
GLOBAL_USAGE = """
local world = tecs.ecs.newWorld()
world:update(1 / 60)
tecs.log.get("game"):info("entities: %d", world:getStats().entities)

return tecs.application.create({
    plugin = function(world: tecs.World, app: tecs.application.Application) print(world ~= nil and app.world ~= nil) end,
})
"""


def checkTealTypes(prefix: Path, tealTypes: str, problems: list):
    """Type-checks a file that uses the `tecs` global against the package."""
    teal = prefix / "share" / "tecs" / "teal"
    if not (teal / "tecs" / "global.d.tl").exists():
        problems.append("no tecs/global.d.tl under share/tecs/teal: a game's `tl check` has no `tecs` global")
        return
    if not shutil.which("tl"):
        print("tl is not installed, so the packaged types were not checked")
        return
    if not tealTypes:
        print("no --teal-types given, so the packaged types were not checked")
        return

    with tempfile.TemporaryDirectory() as scratch:
        usage = Path(scratch) / "usage.tl"
        usage.write_text(GLOBAL_USAGE)
        # Only the package and the LuaJIT declarations, so everything else the
        # types reach for has to be in the package. Running from a scratch
        # directory keeps a tlconfig.lua from lending it a source tree.
        result = subprocess.run(
            [
                "tl",
                "--global-env-def",
                "tecs.global",
                "-I",
                tealTypes,
                "-I",
                str(teal),
                "check",
                str(usage),
            ],
            capture_output=True,
            text=True,
            cwd=scratch,
        )
    if "0 errors detected" not in result.stdout:
        detail = (result.stdout + result.stderr).strip().splitlines()
        problems.append("the packaged Teal types do not check a file using the `tecs` global:")
        problems.extend(f"  {line}" for line in detail)
        return
    print(f"{teal.relative_to(prefix)}: types a file using the `tecs` global")


def libraryStem(reference: str) -> str:
    """Reduces a link-table entry to the library's name, without version or path."""
    name = reference.rsplit("/", 1)[-1]
    name = re.sub(r"\.(dylib|so)(\.[\d.]+)?$", "", name)
    name = re.sub(r"\.[\d.]+$", "", name)
    name = re.sub(r"-[\d.]+$", "", name)
    return name.removeprefix("lib")


def checkLicenses(binary: Path, libs: list, problems: list):
    """Holds a binary's linked libraries against the declared set.

    What this proves is narrow and worth stating: that every library the
    package links is one somebody named, with a license beside it. It does not
    read the license, which is not something a binary carries. A dependency
    that changed its terms between revisions passes here, and so does anything
    linked statically, since a static archive leaves no entry in a link table.
    """
    for lib in libs:
        if lib.startswith(("/usr/lib/", "/System/", "/lib/", "/lib64/")):
            continue
        stem = libraryStem(lib)
        if not any(re.fullmatch(pattern, stem) for pattern, _, _ in LINKED_LIBRARIES):
            problems.append(
                f"{binary.name}: links {stem}, which is not a declared dependency. "
                "Add it to LINKED_LIBRARIES with its license and why it is here, "
                "or take it out. This engine brings in no LGPL."
            )


def machoReferences(binary: Path):
    """Returns (rpaths, linked libraries) for a Mach-O file."""
    out = subprocess.run(["otool", "-l", str(binary)], capture_output=True, text=True)
    rpaths = re.findall(r"cmd LC_RPATH.*?path ([^\s]+)", out.stdout, re.S)

    linked = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True)
    libs = [line.split()[0] for line in linked.stdout.splitlines()[1:] if line.strip()]
    return rpaths, libs


def elfReferences(binary: Path):
    out = subprocess.run(["readelf", "-d", str(binary)], capture_output=True, text=True)
    rpaths = re.findall(r"\(R(?:UN)?PATH\).*\[([^\]]+)\]", out.stdout)
    rpaths = [part for entry in rpaths for part in entry.split(":")]
    libs = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", out.stdout)
    return rpaths, libs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    prefix = Path(sys.argv[1]).resolve()
    allowCompiler = "--allow-compiler" in sys.argv
    tealTypes = ""
    if "--teal-types" in sys.argv:
        tealTypes = sys.argv[sys.argv.index("--teal-types") + 1]

    if not prefix.is_dir():
        sys.exit(f"no such install prefix: {prefix}")

    # A development install links the build machine's libraries on purpose:
    # CMakeLists.txt keeps its link paths deliberately, so it cannot pass the
    # self-contained half of this and no version of it could. Failing it would
    # say nothing about the tree and would train people to ignore the check, so
    # what runs against one is the part that is about the tree rather than the
    # preset, the license position and the packaged types. The rest is
    # reported, and reported as not run rather than as passed.
    info = prefix / "share" / "tecs" / "build-info.txt"
    development = "systemDeps=ON" in info.read_text() if info.exists() else False

    binaries = [
        p for p in prefix.rglob("*") if p.is_file() and (p.suffix in (".dylib", ".so") or (p.parent.name == "bin"))
    ]
    if not binaries:
        sys.exit(f"no binaries found under {prefix}")

    # Kept apart from the list below for the same reason the type check is: what
    # a development install borrows from its machine is allowed to differ, but
    # the license position does not change with the preset. A Homebrew SDL3_image
    # is still SDL3_image, and holding both kinds to this is what makes the
    # check run today rather than only when someone builds a packaged preset.
    licenseProblems = []
    for notice in REQUIRED_NOTICES:
        if not (prefix / notice).exists():
            licenseProblems.append(f"no {notice}: a package that ships the code has to ship the notice")

    problems = []
    for binary in binaries:
        rpaths, libs = machoReferences(binary) if sys.platform == "darwin" else elfReferences(binary)
        checkLicenses(binary, libs, licenseProblems)

        for rpath in rpaths:
            if not rpath.startswith(("@executable_path", "@loader_path", "$ORIGIN")):
                problems.append(f"{binary.name}: search path leaves the package: {rpath}")

        for lib in libs:
            if lib.startswith("/") and not lib.startswith(SYSTEM_PREFIXES):
                problems.append(f"{binary.name}: links an absolute path: {lib}")

        if not allowCompiler:
            for name in COMPILER_NAMES:
                if name in binary.name.lower():
                    problems.append(f"{binary.name}: a shader compiler must not ship in a release")

    # A release ships no compiler, so it has to ship the shaders. An install
    # missing its pack opens a window and then fails at the first pipeline,
    # which is a far worse failure than this one.
    packs = list(prefix.rglob("*.tsp"))
    if not packs:
        problems.append("no shader pack (*.tsp): a release ships no compiler, so it must ship compiled shaders")
    for pack in packs:
        manifest = pack.with_suffix(pack.suffix + ".txt")
        if not manifest.exists():
            problems.append(f"{pack.name}: no manifest beside it, so what it contains cannot be checked")
        else:
            summary = manifest.read_text().splitlines()[1]
            print(f"{pack.relative_to(prefix)}: {summary}")

    # Kept apart from the list above, which is about what a development install
    # is allowed to borrow from its machine. Type information is not borrowed
    # from anywhere: either the package carries it or no game can check against
    # it, so this fails on both kinds of install.
    typeProblems = []
    checkTealTypes(prefix, tealTypes, typeProblems)

    print(f"checked {len(binaries)} binaries under {prefix}")

    if licenseProblems:
        print(f"\n{len(licenseProblems)} problems with the license position:")
        for problem in sorted(set(licenseProblems)):
            print(f"  {problem}")
        sys.exit(1)
    print(f"{len(LINKED_LIBRARIES)} declared dependencies, and the notices to go with them")

    if typeProblems:
        print(f"\n{len(typeProblems)} problems with the packaged types:")
        for problem in typeProblems:
            print(f"  {problem}")
        sys.exit(1)

    if development:
        print("\ndevelopment install: whether it carries its own dependencies was NOT checked.")
        print("Build a packaged preset to check that, for instance PRESET=macos-arm64 make check-package.")
        if problems:
            print(f"\n{len(problems)} references to the build machine, which a packaged preset would not have:")
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
