---
outline: deep
---

# Dependencies

`tecs add` vendors third-party pure-Lua libraries from
[luarocks.org](https://luarocks.org) into a project. The LuaRocks client is
never involved: the CLI talks to the registry directly over the LÖVE
runtime's HTTPS support, so no Lua installation is needed.

```sh
tecs add inspect          # newest version with a source rock
tecs add inspect@2.0-1    # pin a version
tecs remove inspect
tecs update               # re-resolve every added rock (or: tecs update inspect)
```

## What gets vendored

`tecs add` downloads the rock, validates that it is pure Lua, and copies its
modules into `src/vendor/share/lua/5.1/`, along with:

- its dependencies, resolved recursively;
- its license files, kept under `src/vendor/licenses/`;
- matching Teal type declarations, when luarocks.org publishes a
  `<rock>-tl-type` package, so `tecs check` keeps type-checking code that
  requires the rock.

Rocks that need a C compiler (any non-`builtin` build, or native modules)
are rejected. The game runtime is LÖVE's LuaJIT with no toolchain, and the
final build must stay self-contained.

## The manifest

`tecs-rocks.lua` at the project root records every vendored rock, its pinned
version, its dependencies, and its files. Commit it. `src/vendor/` stays
generated and gitignored: `tecs check` and `tecs build` restore any missing
recorded rocks at their pinned versions, so a fresh clone builds without
re-running `tecs add`.

Vendored modules are copied into `build/` like the framework's own runtime
modules, so `tecs dist` packages ship them automatically.
