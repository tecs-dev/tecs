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
whoever receives the binary. That obligation is met by taking those crates
unmodified from crates.io, where their source is public, and by naming them
below. It would stop being met the moment one of them was patched in place, so
do not do that without reading section 3.2 of the licence first.

## What ships

An installed package contains the host executable, the Nupp runtime library,
three native service libraries, a shader pack and the game components. The
inventory beside this file is generated rather than written:

- `cargo-dependencies.txt` names every Rust package in the built graph,
  target- and feature-resolved.
- `cargo-licenses.txt` gives the SPDX expression for each, one line per entry.

`check-package` gates that inventory against what an installed tree actually
links. It reads link tables, so it cannot see inside a static archive and it
cannot read a licence out of a binary, because nothing can.

### The Rust graph

151 packages at the revisions `Cargo.lock` pins. By licence expression:

| Expression | Packages |
| --- | --- |
| MIT OR Apache-2.0, and its spellings | 90 |
| MIT | 18 |
| Zlib OR Apache-2.0 OR MIT | 12 |
| MPL-2.0 | 12 |
| Apache-2.0 | 9 |
| Others: `MIT OR Apache-2.0 OR Zlib`, `BSD-2-Clause OR Apache-2.0 OR MIT`, `Zlib`, `ISC` | 10 |

Everything outside the MPL-2.0 row is permissive and asks only that its notice
travel with a distribution, which `cargo-licenses.txt` and this file do.

### Symphonia, and the only copyleft here

The twelve MPL-2.0 packages are one project: `symphonia` and its bundles,
codecs, formats and metadata crates, which decode audio for the Rust audio
service. They are taken unmodified from crates.io. Their source is at
<https://github.com/pdeljanov/Symphonia>, and that availability is what
satisfies the licence for a binary distribution of a Larger Work.

The audio service chose Symphonia for decoding after measuring what the engine
needs; the licence was not part of that comparison and should have been. It is
recorded here rather than quietly: replacing it is a real option if a
file-level copyleft obligation is not wanted, and the decision belongs to
whoever ships.

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

## What this file is not

It is not a legal review, and the enforcement it once described is gone: the
spec that held the native build's decoder options to their values went with the
Teal engine, along with the options it was holding. What remains is the
generated inventory and `check-package`. A dependency added under an
unacceptable licence would not be caught by anything here, which is worth
knowing before adding one.
