# Contributing to Tecs

Thanks for your interest in contributing!

## Getting set up

A checkout needs three things, and only one of them is installed for you.

**The Nupp compiler on `PATH`.** Use the revision specified in
[Getting started](docs/getting-started.md). With sibling checkouts, run
`export PATH="$(cd ../nupp/bin && pwd):$PATH"` from the Tecs root.

**The Rust toolchain** `rust-toolchain.toml` pins. `rustup` fetches it on the
first build.

**`stylua` and `prettier`**, which format the Lua manifest and the Markdown.
`nupp task deps` installs them on macOS. On other platforms, install both on
`PATH`.

Running the Rust host also needs a Nupp embedding SDK.
`native/rust/winit-host/build.rs` stages one through the compiler's
`scripts/toolchain`, so a sibling checkout covers it; `NUPP_SDK` names a staged
one instead. Nothing else has to be copied by hand; if something does, that is
the defect rather than the workaround.

## Mandatory requirements

- **`nupp task verify` must pass.** It runs the type check, the format check,
  the Nupp suites, the documentation gate, the component builds, and then the
  Rust host's own format, Clippy and test gates. It is what to run before
  pushing, and it fails cheapest first.
- Add tests for new features, bug fixes, or edge cases when reasonable. Suites
  live in `tests/`, and one importing `tecs.internal.*` lives in `tests/tecs/`
  with a forwarder where discovery looks.
- A new externally typed string is added to
  `tests/tecs/compatibilitytest.nupp`, which pins the whole set against
  literals so a later rename fails rather than changing what a save file means.
- **Update the documentation for any user-facing change.** Module
  introductions and examples live in long `--[[ ]]` doc comments; declaration
  docblocks carry symbol contracts, and the generated reference is rendered
  from them. Markdown under `docs/` carries guides that span modules. A change
  a game can see is not done until the relevant source says so.
  `nupp task docs-dev` serves the site while you write.
- **`nupp task docs-check` must pass.** It requires a `description:` on every
  page and refuses an em dash, then renders the site, which is where the rest
  of the gate is: the generator resolves every link and anchor over the output
  it just wrote, and a docblock it cannot read fails there.
- **Public docblocks carry `@param` and `@return`**, and they say what the
  signature cannot: units, coordinate spaces, what nil means, what happens at a
  boundary. A tag that restates the parameter's name is worse than none.
  `@raises` says what makes a function raise, because there is no signature to
  find that out from.

## Code style

`nupp task format` decides layout: indentation, line width, wrapping and
alignment, per language. Run it rather than matching by eye, and do not argue
with it in review.

What it cannot decide is in `STYLE.md`: naming, the file and module split,
early returns over deep nesting, and comments that say why rather than what.
Module documentation uses long `--[[ ]]` comments. Declaration documentation
starts with `---`.

## Changing the Rust services

Four crates sit under `native/rust`: the `winit` host, and the audio, gamepad
and physics services. Each is reached from Nupp through a batched, pull-only
contract, and `AGENTS.md` holds the rule that shapes all of them: **the Rust
side must never call back into a managed function pointer.** Observations come
back by Nupp draining a buffer Rust filled.

The workspace gates are `cargo fmt --all -- --check`,
`cargo clippy --workspace --all-targets -- -D warnings` and
`cargo test --workspace`. `nupp task verify` runs the host's share of them
with the embedding SDK staged, which an ordinary `cargo clippy` over the whole
workspace cannot do on a machine with no compiler checkout beside this one.

## Running the host

```bash
nupp task flatcolor           # A window
nupp task lighting --frames 5 # Five frames, then exit zero
nupp task nativesmoke --headless --frames 2
```

`--frames N` is what makes a graphical example usable as a smoke test, and it
needs at least two: the first completed frame renders, and the following turn
observes the limit.

`nativesmoke` requires all three service libraries directly and raises on the
first that will not load. Every other consumer reaches them through a guarded
require, so a host with nothing staged otherwise looks healthy.

## Packaging

```bash
nupp task package --preset macos-arm64
nupp task check-package
nupp task test-package --preset macos-arm64
```

`check-package` is the gate on the difference between a development preset and
a release one, and only a release install passes it. `test-package` copies the
prefix elsewhere and runs it with an unrelated working directory and every
`TECS_*`, `DYLD_*`, `LD_LIBRARY_PATH` and `NUPP_SDK` override removed, so it
proves the package rather than the build tree.
