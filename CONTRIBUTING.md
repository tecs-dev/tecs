# Contributing to Tecs

Thanks for your interest in contributing!

## Mandatory requirements

- `make test` must pass.
- Add tests for new features, bug fixes, or edge cases when reasonable.
- **Update `docs/` for any user-facing change.** A change a game can see is not
  done until its page says so. Prose is the one thing no test can check, so the
  only defence is the person making the change. `make docs-dev` serves the site
  with hot reload.
- **`make docs-check` must pass.** It holds the module list against
  `src/tecs/init.tl` in three listings at once, resolves every link and anchor,
  requires a `description:` on every page, and diffs each page's generated
  reference against a fresh render. Regenerate with
  `python3 docs/scripts/reference.py` rather than editing below the
  `@generated` marker.
- **Public docblocks carry `@param` and `@return`**, and they say what the
  signature cannot: units, coordinate spaces, what nil means, what happens at a
  boundary. A tag that restates the parameter's name is worse than none.
- `make check` and `make format-check` must pass.

## Code style

`make format` decides layout: indentation, line width, wrapping and alignment,
per language. Run it rather than matching by eye, and do not argue with it in
review.

What it cannot decide is in `STYLE.md`: naming, the file and module split,
early returns over deep nesting, and comments that say why rather than what.
Documentation comments start with `---`.

## Changing the C

The tree is C99 and stays C99. `AGENTS.md` holds why, and the rule that a
header under `native/` has to stay a subset LuaJIT's `ffi.cdef` can parse,
because `scripts/gencdef.py` reads those headers rather than a hand-written
binding.

### Warnings

Every first-party target compiles with a strict warning set, scoped so that
nothing vendored or pinned is held to it. Locally the warnings are warnings.
CI configures with `-DTECS_WERROR=ON`, which makes them errors, and it does that
only for the first-party targets for the same reason the set is scoped that way:
a compiler newer than a pinned revision turns that project's warning into this
project's build failure, which is the problem Mbed TLS already needed
`MBEDTLS_FATAL_WARNINGS OFF` to get out of.

So a change that adds a warning is a change that fails CI. Fix the site rather
than suppressing the check, and where a site is genuinely fine, write the cast
out and say in a comment why it is exact.

### Sanitizers

`macos-arm64-sanitize` and `linux-x64-sanitize` build the C with
AddressSanitizer and UndefinedBehaviorSanitizer under it. Run the host through
them, which means the demo or any benchmark:

```bash
PRESET=macos-arm64-sanitize make run
PRESET=macos-arm64-sanitize make bench-physics
```

Both presets are `RelWithDebInfo`, like every other preset here. They are not a
performance measurement: AddressSanitizer takes the address space
`native/mcodearena.c` reserves for LuaJIT's machine code, so states created
after startup compile fewer traces than they would otherwise, and the arena
reports that by returning false rather than by failing.

**`make test` cannot run under them on macOS.** The spec suite runs under a
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
brew install llvm    # deliberately not in `make deps`
clang-tidy -p out/macos-arm64-dev \
  --extra-arg=-isysroot --extra-arg="$(xcrun --show-sdk-path)" native/*.c
```

The compile database comes from the build tree, which every preset writes.
