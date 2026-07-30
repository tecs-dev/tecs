# Contributing to Tecs

Thanks for your interest in contributing!

## Getting set up

One command, and it is the whole of it:

```bash
cargo xtask deps
```

That installs the Homebrew packages a development build links, then stages
`vendor/`: the pinned Teal compiler, Cerulean, tealdoc, Busted, the Scintillua
lexers, and the Teal type definitions for the modules this tree requires from
outside itself. The last of those is not optional. `cargo xtask check` hands the
compiler `vendor/share/lua/5.1` as an include directory, so a checkout missing
them fails to resolve `ffi` in most of `src` rather than reporting a missing
tool, and the failure looks like broken sources.

**`vendor/` is per checkout and ignored, so a new worktree needs it staged
again.** Homebrew is machine-wide and already done, so that half is
`cargo xtask dev-tools` on its own. Nothing else has to be copied by hand; if
something does, that is the defect rather than the workaround.

`deps` finishes by holding the machine to the versions the build-support crate
pins. It does that because it can break the gate itself: SDL3, SDL3_mixer,
shaderc and LuaJIT are pinned here, Homebrew carries only the current version of
each, and installing the current one is how a machine ends up outside the pin
with every later `cargo xtask` command failing on it. Reporting that where it
happens is the most `deps` can do, since there is no older bottle to ask for.
When it does happen, either raise the pin deliberately, revision and version
together, or set `TECS_ALLOW_VERSION_DRIFT=1` while working on that update.

## Mandatory requirements

- `cargo xtask test` must pass. It runs the Rust workspace tests, checks the
  generated FFI layouts against the C compiler, then runs the Lua and Teal
  spec suites, so this one command is the canonical test gate.
- Add tests for new features, bug fixes, or edge cases when reasonable.
- **Update the generated reference for any user-facing change.** Module
  introductions and examples live in long Teal doc comments; declaration
  docblocks carry symbol contracts. Markdown under `docs/` carries guides that
  span modules. A change a game can see is not done until the relevant source
  says so. `cargo xtask docs-dev` serves the site with hot reload.
- **`cargo xtask docs-check` must pass.** It requires a `description:` on every
  page, then renders the site, which is where the rest of the gate is: the
  `before_build` hook in `tlconfig.lua` holds the pages to `src/tecs/init.tl`,
  and tealdoc resolves every link and anchor over the HTML it just wrote. A
  page's reference is rendered at build time from the modules the page names.
- **Public docblocks carry `@param` and `@return`**, and they say what the
  signature cannot: units, coordinate spaces, what nil means, what happens at a
  boundary. A tag that restates the parameter's name is worse than none.
- `cargo xtask check` and `cargo xtask format-check` must pass.

## Code style

`cargo xtask format` decides layout: indentation, line width, wrapping and
alignment, per language. Run it rather than matching by eye, and do not argue
with it in review.

What it cannot decide is in `STYLE.md`: naming, the file and module split,
early returns over deep nesting, and comments that say why rather than what.
Module documentation uses long `--[=[ ... ]=]` comments. Declaration
documentation starts with `---`.

## Changing the C

The tree is C99 and stays C99. `AGENTS.md` holds why, and the rule that a
header under `native/` has to stay a subset LuaJIT's `ffi.cdef` can parse,
because the Cargo binding generator reads those headers rather than a
hand-written binding.

### Warnings

Every first-party target compiles with a strict warning set, scoped so that
nothing vendored or pinned is held to it. Locally the warnings are warnings.
CI sets `TECS_WERROR=1`, which makes them errors, and it does that only for the
first-party targets for the same reason the set is scoped that way: a compiler
newer than a pinned revision turns that project's warning into this project's
build failure.

So a change that adds a warning is a change that fails CI. Fix the site rather
than suppressing the check, and where a site is genuinely fine, write the cast
out and say in a comment why it is exact.

### Sanitizers

`macos-arm64-sanitize` and `linux-x64-sanitize` build the C with
AddressSanitizer and UndefinedBehaviorSanitizer under it. Run the host through
them, which means the demo or any benchmark:

```bash
cargo xtask run --preset macos-arm64-sanitize
cargo xtask bench physics --preset macos-arm64-sanitize
```

Both presets are `RelWithDebInfo`, like every other preset here. They are not a
performance measurement: AddressSanitizer takes the address space
the Rust host reserves for LuaJIT's machine code, so states created
after startup compile fewer traces than they would otherwise, and the arena
reports that by returning false rather than by failing.

**`cargo xtask test` cannot run under them on macOS.** The spec suite runs under a
plain interpreter that loads the instrumented libraries with `dlopen`, so the
sanitizer runtime has to be inserted with `DYLD_INSERT_LIBRARIES`, and macOS
strips every `DYLD_` variable when it launches a protected binary. `busted` is a
`/bin/sh` wrapper, so the variable is gone before the interpreter starts and
AddressSanitizer reports that its interceptors are not installed. What runs
under the sanitizers is the host, which links the runtime directly and needs no
variable at all. Reach the code a benchmark does not by writing an entry chunk
and giving it to `--entry`.

Leak detection is off: it is unsupported on macOS arm64, and on Linux both
LuaJIT and the graphics driver hold allocations to exit by design.

### clang-tidy

`.clang-tidy` holds a curated check set, and the comments in it say why each
disabled check was disabled. It is not a gate; the compiler's warnings are.

```bash
brew install llvm    # deliberately not in `cargo xtask deps`
clang-tidy -p out/macos-arm64-dev \
  --extra-arg=-isysroot --extra-arg="$(xcrun --show-sdk-path)" native/*.c
```

The compile database comes from the build tree, which every preset writes.
