# Tecs Style Guide

Conventions for Teal code in Tecs and in projects built on it. The
goal is code that reads uniformly, type-checks strictly, and stays fast on
LuaJIT. Where this guide and existing code disagree, the guide wins for new
code; migrate old code opportunistically.

## Files and modules

- One concern per file. Most files are either a **class** (one dominant
  type you construct and call methods on, including component records) or a
  **module** (a namespace of functions and data). Declaration files
  (`.d.tl`), entrypoints, tests, and generated or macro-support files sit
  outside that split and follow the conventions of their kind.
- Class files and their import bindings are **PascalCase**: `Camera.tl`,
  `local Camera <const> = require("tecs.gfx.Camera")`.
- Module files and their bindings are **luacase** (all lowercase, no
  separators): `bucketmanager.tl`, `local bucketmanager <const> = ...`.
  Never snake_case, never camelCase for module names.
- Prefer a single word when an unambiguous one exists: `behavior`, not
  `frameworkbehavior`. Keep compounds only when needed (`bucketmanager`).
- Prefer flat `module.tl` over `module/init.tl` unless the module has
  internal submodules.
- The require path mirrors the filename, and the local binding matches the
  last path segment by default. Aliases are fine when they communicate role
  or prevent ambiguity: `local C <const> = require("ffi")`, or
  distinguishing a public module from an internal one with the same name.
- Package roots use `init.tl`; public leaf modules may be named `.tl` files
  (`tecs.input`, `tecs.tween`, `tecs.utils.logging`). Internal helpers
  live under `internal/` and are not part of the supported surface.

## Formatting and alignment

No formatter is adopted yet. Cerulean is the closest candidate but is not
ready (as of 1.8.0 it corrupts `macroexp` bodies and nested generic function
types); revisit when those are fixed upstream. Until then, formatting is by
hand:

- 4-space indentation. No tabs.
- Keep lines reasonable; wrap long signatures with one parameter group per
  line, closing parenthesis on the final line:

  ```teal
  init: function(
      world: World, entity: integer, relative: boolean,
      t1: number, t2: number, t3: number, t4: number
  ): number, number
  ```

- Multi-line call arguments hug the call: `f({` on the call line, fields
  indented, `})` closing.
- Group `require`s at the top of the file, followed by `local type` aliases.
- Align record fields with a single space around `:`. Do not column-align
  values or types; alignment breaks on rename and churns diffs.
- Prefer early returns over nested conditionals.
- Comments are sparse and informational. Public functions, records, and
  modules get `---` doc comments describing behavior and constraints, not
  restating the signature. No commented-out code.

## Naming

These rules apply to identifiers and schema keys **that Tecs controls**.
Names fixed elsewhere are preserved verbatim: established MCP tool names
(`run_lua`, `send_event`), FFI and C symbols, external Lua APIs, Lua
metamethods (`__call`, `__index`), and generated bindings.

- Functions, methods, record fields, option keys, and locals: **camelCase**.
  No snake_case in Tecs-controlled identifiers.
- Types (records, interfaces, enums, aliases): **PascalCase**.
- `SCREAMING_SNAKE_CASE` is for tunables: values that parameterize the
  system and that you would document as configuration (`DEFAULT_PORT`,
  `STARTUP_TIMEOUT`, buffer sizes, magic numbers). A binding that merely
  never reassigns (an import, a hoisted function, a computed value) is
  `<const>` camelCase.
- Booleans read as predicates: `isRunning`, `hasHoles`, `defaultFixedRotation`.
- New event/data string keys exposed to tooling (snapshot data keys, custom
  MCP data) are namespaced with dots: `"myGame.gameState"`.

## Bindings

- Every import and module-level binding is `local x <const> = ...`.
- Hoist hot standard-library functions into `<const>` locals in
  performance-sensitive modules:
  `local mathSin <const> = math.sin`.
- Use `local type X = pkg.Y` aliases to keep signatures short:
  `local type World = tecs.World`.

## Typing discipline

- **`any` is a last resort.** Reach for it only at genuine dynamic
  boundaries: parsed JSON, `pcall` results, FFI cdata crossings, `run_lua`
  style embedding. Cast back to a concrete type at the first opportunity and
  keep the `any` region as small as possible. A helper that takes and
  returns `any` is a design smell; give it a generic or a union instead.
- Prefer **unions** over `any` when the value is one of a known set:
  `local type ControlSelector = string | Timeline`.
- Prefer **generics** over `any` when the type flows through:
  `eventually: function<T>(seconds: number, fn: function(): T): T`.
- Use `as` casts sparingly and locally, with a comment when the reason is
  not obvious. A cast is an assertion you are making to the compiler; make
  it where the invariant is established, not downstream.
- Mark optional parameters with `?`. Teal cannot mark record fields
  optional, so state a field's optionality in its doc comment, handle `nil`
  explicitly at every use site, and validate required fields at construction
  time. Do not overload `nil` to mean multiple things.
- Type every public signature fully, including returns. Multiple returns are
  fine; more than three suggests a record.
- Declare external formats in `.d.tl` files; never hand-wave them as `any`.
  Dynamic requires that Teal cannot resolve go through a variable
  (`pcall(require, moduleName)`), since literal requires are statically
  checked even inside `pcall`.

## Records and interfaces

- **Records** describe concrete data: components, options tables, plain
  structs. Keep them flat; nested records are for genuinely nested data.
- **Interfaces** describe capabilities and families:
  `interface Component`, `interface ScalarComponent<T> is Component`. Use
  `is` for refinement and `where` for structural predicates
  (`interface Relationship is Component where self.relationshipType ~= nil`).
- Options tables are records with names ending in `Options` or `Config`
  (plain `Options` when a module has one; descriptive like
  `RecordingOptions` when it has several), declared next to the function
  that takes them, every field documented, optionality explicit.
- Methods on a class record take `self` typed as the record:
  `isRunning: function(self: Proc): boolean`.
- Enums for closed string sets (`enum BlendMode ... end`) instead of bare
  `string` fields.

## Components

- Declare the container record with the interface:

  ```teal
  local record Velocity is tecs.Component
      x: number
      y: number
  end
  ```

- **FFI vs table storage**: `tecs.newFFIComponent` requires data that maps
  cleanly to a C struct (numbers, booleans, fixed-size arrays) and pays off
  when the component is iterated densely: contiguous, cache-friendly
  columns. It also carries conversion, lifetime, and tooling tradeoffs, so
  choose it for measured hot data, not by default. Use `tecs.newComponent`
  (table storage) when fields hold Lua tables, varying strings, functions,
  or userdata, or when the component is cold. Do not
  mix: if one field needs a table, the component is a table component.
- Tag components (no fields) beat boolean fields when the flag is stable
  and queried often: queries match archetypes directly instead of scanning.
  A frequently toggled tag moves entities between archetypes every flip; a
  boolean field is the right call for high-frequency toggles.
- Give every component a `name` matching its record name; tooling (queries,
  MCP, snapshots) uses it.
- Keep components as data. Behavior belongs in systems; a `metamethod
  __call` constructor is the accepted exception.

## Systems

- Add behavior through systems, added in plugins. Every persistent system
  gets a `name` (PascalCase, e.g. `"GameplayPauseInput"`); the debugger,
  MCP tools, and profiles are unreadable without names.
- Pick the correct `phase`; do not do render work in `Update` or game logic
  in `Render`.
- Gate with `runIf` rather than early-returning inside `run` when the
  condition is state-shaped. Use `tecs.runif.*` predicates for common gates
  and custom predicates when combining checks.
- Systems receive `dt`; never read wall clocks in game logic.
- The host owns the loop. An entry file returns `tecs.application(config)`
  and its callbacks run from there; nothing drives frames itself.

## Queries

- Create queries **once, during plugin setup**, and reuse them across the
  system's lifetime. Never create a query inside `run`.
- Name persistent queries (`world:query({name = "GameStateEntities", ...})`).
- Iterate archetype-wise and bind columns once per archetype:

  ```teal
  for archetype, len, entities in spriteQuery:iter() do
      local transforms = archetype:get(Transform)
      local sprites = archetype:get(Sprite)
      for row = 1, len do
          -- transforms[row], sprites[row], entities[row]
      end
  end
  ```

- `archetype:get` for read-only columns, `archetype:getMut` when writing;
  `world:getMut(entity, Component)` when mutating a component fetched by id.
  Skipping the mut variants silently breaks dirty tracking.
- Prefer `world:batchDespawn`, `batchSet`, and `batchRemove` for bulk
  changes over per-entity loops.

## Plugins, resources, and state

- Plugins are the unit of composition: register components, create queries,
  add systems, install observers. Keep each plugin focused enough to test.
- Share globals through `world.resources[...]`, keyed by a typed resource
  key. No Lua globals in game code.
- Entities spawned while a state is on top receive that state's auto-tag;
  spawn deliberately relative to state lifecycles.
- Use observers (`world:observe`) for lifecycle events instead of polling.

## Errors and logging

- `error(msg, 0)` for user-actionable failures with a message that says what
  to do next; reserve stack levels for programmer errors.
- Log through `tecs.utils.logging` with a named logger
  (`logging.getLogger("tecs-mcp")`), not `print`.
- Validate options at construction time with clear messages; do not defer
  failures into the first frame.

## Performance

- Avoid allocations in **measured hot loops** (dense query iteration,
  render, storage sync): no closures, table constructors, or varargs
  packing there. Cold per-frame work (UI, debug overlays, low-frequency
  systems) does not justify pooling; benchmark before introducing reusable
  buffers or pools.
- Prefer numeric `for` over `ipairs` in hot loops; prefer column iteration
  over per-entity component fetches.
- FFI structs for bulk numeric data; measure before and after with the bench
  harness when touching storage, rendering, or snapshot paths.

## Tests

- Specs run headless under Busted. The engine's are Lua under `spec/`; the
  ECS's are Teal under `spec/tecs/`. Both are collected by one `make test`.
- Assert with luassert's flat API (`luassert.equal`, `luassert.is_true`).
- Do not sleep and hope: drive a deterministic number of frames and assert
  on what they produced.
