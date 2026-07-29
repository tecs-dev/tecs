# Contributing to Tecs

Thanks for your interest in contributing!

## Mandatory requirements

- `cargo xtask test` must pass.
- Add tests for new features, bug fixes, or edge cases when reasonable.
- **Update `docs/` for any user-facing change.** A change a game can see is not
  done until its page says so. Prose is the one thing no test can check, so the
  only defense is the person making the change. `cargo xtask docs-dev` serves the site
  with hot reload.
- **`cargo xtask docs-check` must pass.** It requires a `description:` on every
  page, then renders the site, which is where the rest of the gate is: the
  `before_build` hook in `tlconfig.lua` holds the pages to `src/tecs/init.tl`,
  and tealdoc resolves every link and anchor over the HTML it just wrote. A
  page's reference is rendered at build time from the modules the page names,
  so nothing below the `@generated` marker is written into the tree.
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
Documentation comments start with `---`.

## Changing the C

The tree is C99 and stays C99. `AGENTS.md` holds why, and the rule that a
header under `native/` has to stay a subset LuaJIT's `ffi.cdef` can parse,
because the Cargo binding generator reads those headers rather than a
hand-written binding.

### Warnings

Every first-party target compiles with a strict warning set, scoped so that
nothing vendored or pinned is held to it. Locally the warnings are warnings.
CI configures with `-DTECS_WERROR=ON`, which makes them errors, and it does that
only for the first-party targets for the same reason the set is scoped that way:
a compiler newer than a pinned revision turns that project's warning into this
project's build failure.

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
