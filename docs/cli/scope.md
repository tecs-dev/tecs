---
description: "What the tecs command deliberately will not do, and how its offline reference shares one content tree with this site"
outline: deep
---

# Scope

::: warning Not built yet
The `tecs` command does not exist on this branch. This page records the shape it is planned to take so that
nothing else in the site has to pretend it is already there. Everything below is a plan, not a reference, and
the commands cannot be run today.

Build and run through `make` in the meantime. See [getting started](/getting-started).
:::

## What it will not do

**It does not wrap CMake or Make.** CMake and Make build the engine and the tool. The tool builds games. Those are
different jobs with different inputs, so there is no second implementation and no shelling out to Make from a
user's machine. `make run` runs this repository's own demo, which is a test of the engine; `tecs run` builds and
runs a project. Both stay, and neither delegates to the other.

**It does not cross-compile.** A macOS host cannot produce a Windows game and the reverse is worse, since a Mach-O
needs an SDK whose licence forbids redistributing it. `tecs dist` packages for the platform it is running on, and
`tecs new` scaffolds a CI workflow with a three-OS matrix that runs it on each.

## Offline documentation

This site and the tool's offline reference are meant to be one content tree, not two. Every page here carries a
one-line `description:` in its frontmatter for exactly that reason: the descriptions label pages in the generated
`llms.txt` index and in an offline reference. `scripts/check-docs-descriptions.sh` gates it, and `make docs-check`
runs it.
