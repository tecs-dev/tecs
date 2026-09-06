# Third-Party Notices

Tecs links third-party material under licences other than the repository's
MIT-or-Apache-2.0 code licence. This file installs to `share/tecs` beside the
binaries it describes, with `LICENSE-MIT` and `LICENSE-APACHE`, and the Nupp
runtime's own notices install to `share/tecs/notices`. A package that carried
the code and not the notice is the one compliance failure this engine could
commit on its own.

## The rule

**No LGPL, and no GPL.** Not as a preference and not per release: a game built
on this engine ships as a small set of binaries per platform, and the LGPL's
relinking obligation is not a thing that arrangement can offer. A dependency
under either is not adopted, however convenient it is.

**MPL-2.0 is accepted, and it is not permissive.** It is file-level copyleft:
distributing a Larger Work under other terms is explicitly allowed, and what it
asks in return is that the source of the covered files stays available to
whoever receives the binary. The distribution records exact source versions,
download locations and verified modification status as described below.
Patched covered sources require their actual source and modification records
before packaging will accept them.

## What ships

An installed package contains the host executable, the Nupp runtime library,
three native service libraries, a shader pack and the game components. The
inventory beside this file is generated rather than written:

- `cargo-dependencies.txt` names every Rust package in the built graph,
  target- and feature-resolved.
- `cargo-licenses.txt` gives the SPDX expression for each, one line per entry.
- `license-sources.json` gives version-specific source URLs, locked archive
  checksums and verified modification status for covered MPL-2.0 crates.

`check-package` gates that inventory against what an installed tree actually
links. It reads link tables, so it cannot see inside a static archive and it
cannot read a licence out of a binary, because nothing can.

### The Rust graph

`cargo-dependencies.txt` records the resolved target/feature graph, including
build dependencies. Its count changes with the lockfile; `cargo-licenses.txt`
records the exact version and declared SPDX expression for each entry.

### Symphonia and covered source

Tecs retains Symphonia and accepts MPL-2.0 for its covered files. The project
repository is <https://github.com/pdeljanov/Symphonia>, but a moving repository
URL alone does not identify the source used for an installed binary.

Each package therefore includes `license-sources.json`, with one entry for each
MPL-2.0 crate in the resolved inventory. An entry names the exact crate version,
its version-specific crates.io source download URL, the archive SHA-256 from
Cargo.lock, and a modification list. The current list is empty because packaging
verifies that the archive matches Cargo.lock and that every source file used by
Cargo matches that archive, with no extra source files. Cargo's own extraction
receipt is excluded from that comparison.

A patched, vendored, git or locally modified covered crate cannot inherit an
unmodified upstream source claim: packaging refuses it. Supporting one requires
shipping its actual modified source and an explicit modification record first.
`check-package` requires this manifest and cross-checks its covered package
versions against the shipped license inventory. Recipients obtain the matching
covered source through the recorded version-specific download links.

### The Nupp runtime

`libnupp` carries LuaJIT, LPeg and lunajson. Each is permissive and each asks
for its copyright notice to travel with a distribution, so packaging copies the
Nupp distribution's own notices to `share/tecs/notices` rather than restating
them here, where they would go stale against the compiler this tree pins.

## In this repository but not in a package

### JetBrains Mono

`assets/fonts/JetBrainsMono-ExtraBold.ttf` is JetBrains Mono, under the SIL
Open Font License 1.1. The tests read it. It is not installed by a package
today; a package that starts shipping a font has to carry the OFL text with it.

## Scope of the checks

The generated inventory and source manifest make shipped dependency names,
versions, notices and covered-source provenance reviewable. Link-table inspection
cannot identify every crate embedded in a static archive or infer a license from
a binary. Dependency adoption still follows the license policy above; the gate
checks complete records rather than making legal decisions from an SPDX string.
