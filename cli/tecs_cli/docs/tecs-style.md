# Tecs style guide (game-project subset)

Conventions for idiomatic, strictly-typed, LuaJIT-fast Teal in a Tecs game — the game-relevant subset of the framework's `STYLE.md`.

## Naming

- Functions, methods, record fields, option keys, locals: **camelCase**. No snake_case in
  identifiers you control.
- Types (records, interfaces, enums, aliases): **PascalCase**. Systems get PascalCase `name`s
  (`"GameplayPauseInput"`).
- `SCREAMING_SNAKE_CASE` only for tunables/config constants (`DEFAULT_PORT`, `CELL_SIZE`). A
  binding that just never reassigns (import, hoisted fn) is `<const>` camelCase.
- Booleans read as predicates: `isRunning`, `hasHoles`.
- Preserved verbatim: MCP tool names (`run_lua`), FFI/C symbols, Lua metamethods (`__call`).

## Bindings

- Every import and module-level binding is `local x <const> = ...`.
- Alias types to keep signatures short: `local type World = tecs.World`.
- In hot modules, hoist stdlib functions: `local mathSin <const> = math.sin`.

## Typing discipline

- **`any` is a last resort** — only at dynamic boundaries (parsed JSON, `pcall`, FFI, `run_lua`).
  Cast back to a concrete type immediately and keep the `any` region tiny.
- Prefer **unions** for a known set (`string | Timeline`) and **generics** when a type flows
  through (`function<T>(seconds: number, fn: function(): T): T`).
- Type every public signature fully, including returns. More than three returns → use a record.
- Options tables are records named `...Options` / `...Config`, declared next to their function,
  every field documented, optionality explicit.
- Use enums for closed string sets instead of bare `string` fields.

## Components

- Declare the container with the interface: `local record Velocity is tecs.Component`.
- **FFI vs table storage:** `newFFIComponent` for measured hot numeric/boolean data iterated
  densely; `newComponent` (table) when a field holds a Lua table/string/function/LÖVE object, or
  when the component is cold. Don't mix — one table field makes it a table component.
- Tag components beat boolean fields for **stable, frequently-queried** flags; a boolean field is
  right for high-frequency toggles (a tag flip moves the entity between archetypes each time).
- Keep components as data. Behavior lives in systems (`metamethod __call` constructor is the
  accepted exception).

## Systems

- Add behavior through systems, registered in plugins. Every persistent system needs a `name`.
- Pick the correct `phase`; no render work in `Update`, no game logic in `Render`.
- Gate with `runIf` (and `tecs.runif.*`) rather than early-returning inside `run` for state-shaped
  conditions. Systems receive `dt`; never read wall clocks.
- Don't add manual `love.update`/`love.draw`; `tecs2d.run` owns the loop.

## Queries

- Create queries **once during plugin setup** and reuse them; never inside `run`. Name persistent
  queries.
- Iterate archetype-wise, binding columns once per archetype; use numeric `for row = 1, len do`.
- `archetype:get` to read, `archetype:getMut` to write (`world:getMut(id, C)` by id). Skipping the
  mut variants silently breaks dirty tracking.
- Prefer `world:batchDespawn` / `batchSet` / `batchRemove` over per-entity loops.

## Plugins, resources, state

- Plugins are the unit of composition: register components, create queries, add systems, install
  observers. Keep each focused enough to test.
- Share globals through `world.resources[...]` keyed by a typed resource key — no Lua globals.
- Use observers (`world:observe`) for lifecycle events instead of polling.

## Errors, logging, performance

- `error(msg, 0)` for user-actionable failures with a next-step message. Validate options at
  construction time, not on the first frame.
- Log through `tecs.utils.logging.getLogger("name")`, not `print`.
- Avoid allocations in **measured** hot loops (no closures/table constructors/varargs there);
  don't pre-pool cold per-frame work. Benchmark before optimizing storage/render/snapshot paths.

## Tests

- `*_spec.tl` run headless under busted; `*_lovespec.tl` boot a real app via
  `tecs2d.testing.fixture` and drive it over MCP.
- Assert with luassert's flat API (`luassert.equal`, `luassert.is_true`).
- Poll time-dependent assertions with `fixture.eventually`; don't sleep and hope. Boot one app per
  `describe` and walk it through states in order.

See also: `tecs docs tecs-ecs`, `tecs docs tecs-gotchas`.
