---
description: "What the tecs command deliberately will not do, and how its offline reference shares one content tree with this site"
outline: deep
---

# Scope

## What it does not do

**It does not wrap the repository build.** Cargo builds the engine and the
tool. The tool builds games. Those are different jobs with different inputs,
so there is no second implementation and no shelling out to Cargo from a
user's machine. `cargo xtask run` runs this repository's own demo, which is a
test of the engine; `tecs run` builds and runs a project.

**It does not cross-compile.** A macOS host cannot produce a Windows game and
the reverse is worse, since a Mach-O needs an SDK whose license forbids
redistributing it. The current command builds and runs projects on the platform
where it is invoked; release packaging is not part of its command surface.

## Offline documentation

This site and `tecs docs` are one content tree, not two. Every page here carries
a one-line `description:` in its frontmatter for exactly that reason: the
descriptions label pages in the offline index. Product staging copies the
Markdown into the CLI content root, and the one-file build compresses that root
into its payload. `cargo xtask docs-check` gates the source pages.
