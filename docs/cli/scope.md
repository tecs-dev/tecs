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

**It does not cross-compile.** A macOS host cannot produce a Windows game and the reverse is worse, since a Mach-O
needs an SDK whose license forbids redistributing it. `tecs dist` packages for the platform it is running on, and
`tecs new` scaffolds a CI workflow with a three-OS matrix that runs it on each.

## Offline documentation

This site and the tool's offline reference are meant to be one content tree, not two. Every page here carries a
one-line `description:` in its frontmatter for exactly that reason: the descriptions label pages in the generated
`llms.txt` index and in an offline reference. `cargo xtask docs-check` gates it.
