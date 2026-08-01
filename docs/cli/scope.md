---
description: "The boundary between project commands and the repository build, plus the offline documentation source"
outline: deep
---

# Scope

## Project and engine builds

Cargo builds the engine and the CLI. The CLI builds games.
`cargo xtask example ui-demo` runs this repository's showcase; `tecs run` builds
and runs a project.

The CLI builds for its host platform. It does not cross-compile or package
releases.

## Offline documentation

This site and `tecs docs` read the same Markdown. Page descriptions label the
offline index. Product staging copies the pages into the CLI payload, and
`cargo xtask docs-check` validates them.
