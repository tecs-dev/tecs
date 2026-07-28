# huh2

A game built on tecs, a typed entity component system and the engine around
it. `tecs` is one executable and is the whole toolchain: type checker,
formatter, test runner and build, at one pinned set of revisions.

## Commands

```bash
tecs check     # Type-check src/
tecs format    # Format sources in place
tecs test      # Compile and run spec/
tecs build     # Compile src/, stage assets, write build/
tecs run       # Build, then launch the game
tecs clean     # Remove build/
tecs info      # Versions, project status, what can be packaged here
```

Every command searches upward for `tecs.lua`, so all of them work from any
directory inside the project.

## Layout

```text
huh2/
├── tecs.lua        # What this project is. The marker and the manifest.
├── tlconfig.lua    # Teal and Cerulean configuration. Not the marker.
├── src/main.tl     # Entry point. Returns an application.
├── spec/           # Specs, run by `tecs test`
├── assets/         # Images, sounds, fonts, shaders
└── build/          # Compiled output. Not checked in.
```

## Writing the game

Entities are the interface. Anything that renders or updates per frame is an
entity in a world, and the game is a plugin handed the world and the
application.

The rules that prevent the most common defect class:

- Reads use `archetype:get` / `world:get`; writes go through `getMut`, which
  marks the component's column dirty. Never `getMut` in a loop that might not
  write: it defeats every dirty-gated consumer.
- Direct cdata writes through `world:get` on FFI components need an explicit
  `world:markComponentDirty(id, Component)` or the GPU never re-syncs.
- `world:batchSpawn` skips FFI defaults; set every field in the callback.
- Keep `query:iter()` for loops that run to exhaustion. A loop that may `break`
  or return early uses `query:cursor()` and closes the cursor, because leaving
  one early through `iter` leaves the world deferred and silently queues every
  later spawn.

## Style

`tecs format` decides layout: indentation, columns, wrapping, alignment. What
is left to a person is `local` and `<const>` where appropriate, early returns
over deep nesting, comments sparse and informational, and camelCase for every
identifier.

Do not scaffold a second project inside this one. Implement in `src/`.
