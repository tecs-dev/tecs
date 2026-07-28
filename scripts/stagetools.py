"""Stages the pinned Teal compiler and Cerulean formatter into the content root.

`tecs check`, `tecs build`, `tecs test` and `tecs format` all run one of these
two, and both are pure Lua, so both travel inside the binary rather than being
resolved on a user's machine. `cmake/Revisions.cmake` names the commit of each
and `scripts/install-dev-tools.sh` puts them in the ignored vendor tree; this
copies exactly what a running `tecs` needs out of that tree and nothing else.

**An explicit manifest rather than a directory copy.** The vendor tree is a
LuaRocks install and holds `.tl` sources beside the compiled `.lua`, rockspecs,
declaration files for libraries nothing here uses, and C modules that a single
executable has no way to load. Copying it wholesale would double the payload
and would ship a `.so` that resolves on the build machine and nowhere else.

**LuaFileSystem is deliberately absent.** Both tools require it, and it is a C
module. `cli/tecscli/lfsshim.tl` answers the three functions they call, over
SDL, which the engine already links.
"""

import argparse
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Single files, copied as they are.
FILES = (
    # The Teal compiler's own entry module. Cerulean requires it by this name.
    "tl.lua",
    # The argument parser both command line front ends are written against.
    "argparse.lua",
)

# Whole packages, taking their `.lua` and leaving the `.tl` they were built
# from. A compiler shipped with its own source doubles the payload to describe
# code that is already there in compiled form.
PACKAGES = (
    "teal",
    "tlcli",
    "cerulean",
)

# Declaration files a project's `tl check` needs and no compiler carries.
# These are what the engine's own sources are written against, and without them
# a check fails inside tecs rather than on anything a user wrote: `string.buffer`
# and `table.new` are LuaJIT extensions the ECS's storage is built on, and their
# declarations sit in directories named after the module rather than the file.
DECLARATIONS = (
    "bit.d.tl",
    "buffer.d.tl",
    "cjson.d.tl",
    "ffi.d.tl",
    "jit.d.tl",
    "string/buffer.d.tl",
    "table/clear.d.tl",
    "table/new.d.tl",
)

# Licenses travel with the code they cover. A binary carrying the compiler and
# not its notice is the one license failure this is capable of committing.
LICENSES = (
    ("teal/LICENSE", "teal-LICENSE"),
    ("cerulean/LICENSE", "cerulean-LICENSE"),
    ("cerulean/MIT-teal.txt", "cerulean-MIT-teal.txt"),
)


def copyFile(source: Path, target: Path, staged: list):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    staged.append(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", required=True, help="the vendor rock tree, e.g. vendor/share/lua/5.1")
    parser.add_argument("--licenses", required=True, help="vendor/licenses")
    parser.add_argument("--out", required=True, help="where to stage them")
    args = parser.parse_args()

    vendor = Path(args.vendor)
    out = Path(args.out)
    if not vendor.is_dir():
        sys.exit(f"tecs: {vendor} is not there. Run `make dev-tools`.")

    staged = []
    for name in FILES + DECLARATIONS:
        source = vendor / name
        if not source.is_file():
            sys.exit(f"tecs: {source} is missing from the vendor tree. Run `make dev-tools`.")
        copyFile(source, out / name, staged)

    for package in PACKAGES:
        root = vendor / package
        if not root.is_dir():
            sys.exit(f"tecs: {root} is missing from the vendor tree. Run `make dev-tools`.")
        for source in sorted(root.rglob("*.lua")):
            copyFile(source, out / package / source.relative_to(root), staged)

    licenses = Path(args.licenses)
    for relative, name in LICENSES:
        source = licenses / relative
        if source.is_file():
            copyFile(source, out / "licenses" / name, staged)

    print(f"staged {len(staged)} files into {out}")


if __name__ == "__main__":
    main()
