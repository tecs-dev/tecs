# Tecs Style Guide

Conventions for Nupp code in Tecs and in projects built on it. The goal is code
that reads uniformly, type-checks strictly, and stays fast. Where this guide and
existing code disagree, the guide wins for new code; migrate old code
opportunistically.

## Files and modules

Game code and public examples use fully qualified `tecs` paths for values and
types. Nupp resolves them without an import prelude and hoists their module
loads, including calls inside hot loops. Keep `tecs` unshadowed. Existing
engine-local bindings follow the naming rules below; use dynamic `require`
only when loading on first use is part of the behavior.

- One concern per file, and a file is a **module**: a namespace of functions,
  types and values. Types and component definitions live inside the module that
  owns them rather than in files of their own.
- Module files and their import bindings are **luacase**: all lowercase, no
  separators, so `rendercomponents.nupp` binds as
  `local rendercomponents = require("tecs.internal.rendercomponents")`. Never
  snake_case, never camelCase for module names.
- Prefer a single word when an unambiguous one exists: `layers`, not
  `layermanager`. Keep compounds only when needed (`rendercomponents`).
- Prefer a flat `module.nupp` over `module/init.nupp` unless the module has
  children. A module with children must live in `name/init.nupp`.
- The require path mirrors the filename, and the local binding matches the last
  path segment by default. Aliases are fine when they communicate role or
  prevent ambiguity, such as distinguishing a public module from an internal
  one with the same name.
- Internal helpers live under `internal/` and are not part of the supported
  surface. The compiler enforces it: a module may statically import
  `tecs.internal.*` only if its own first namespace segment is `tecs`.
- Every `src/tecs/**.nupp` module is listed in the `headless` target's
  `entries` in `nupp.lua`. One that is not is neither built nor checked.

## Layout, which the formatter owns

`nupp task format` decides all of this and `nupp task format-check` fails
on it, so none of it is worth reading a diff for or asking about in review. It
is written down because knowing what the tool will do is how you stop fighting
it, not because anybody has to apply it.

- 4-space indentation, no tabs, and 120 columns.
- Long signatures wrap with one parameter per line and the closing parenthesis
  on its own:

  ```nupp
  export function create(
      title: string?,
      width: integer?,
      height: integer?,
      debug: boolean?
  ): host.Session
  ```

- A call with a single table argument hugs it: `f({` on the call line, fields
  indented, `})` closing.
- Record fields take a single space around `:`. Values and types are not
  column-aligned, because alignment breaks on the first rename and churns the
  diff of every line around it.

## Human decisions

These are judgment, and they are what a review is for.

- Group `require`s at the top, followed by type aliases. The formatter
  deliberately does not sort them: import order is meaningful where one module
  has to be reached before another runs, so a tool that reordered them could
  change behavior.
- Prefer early returns over nested conditionals.
- Comments are sparse and informational. Public modules start with a long
  `--[[ ... ]]` doc comment. Public functions, records, and fields use `---`
  docblocks. Documentation describes behavior and constraints rather than
  restating the signature. No commented-out code.
- Names, and the file and module split above, which no tool can check.

## Formatters

`nupp task format` applies them and `nupp task format-check` reports
without writing. The suffix table lives in `tools/tecs/dev/format.nupp`.
Every tool is configured to the two rules above, and none of them reflows a
comment body.

```
 Language  Tool             Config
 ────────  ───────────────  ─────────────
 Nupp      the compiler     nupp.lua
 Lua       stylua           .stylua.toml
 Rust      rustfmt          rustfmt.toml
 Web       prettier         .prettierrc
```

Prettier covers JSON, Markdown, YAML, CSS and the JS/TS family. Markdown is
formatted with `proseWrap: preserve`, so hand-wrapped prose keeps its line
breaks and only structure is normalized.

Nupp and Cargo format their own trees rather than a file list, so naming paths
on the command line narrows the run to the suffix-dispatched tools alone.

WGSL is deliberately unformatted. There is no formatter for it in this
toolchain, and the shaders under `assets/` are hand-formatted to the rules
above.

## Naming

These rules apply to identifiers and schema keys **that Tecs controls**.
Names fixed elsewhere are preserved verbatim: established MCP tool names
(`run_lua`, `send_event`), native symbols, and metamethods (`__call`,
`__index`).

"That Tecs controls" is narrower than it looks, and `AGENTS.md` holds the
long form under "Externally typed strings are a separate compatibility
surface". The short version: a snapshot key, a logger name, a component or
event name, a system name, an MCP tool name and a pass name are all reached
from outside this tree, by a save file, a shell, or an agent. Moving the
module they live in does not move them, and a module that has moved keeps
strings that will read as oversights afterwards. Say at the declaration that
the string is a compatibility surface.
`tests/tecs/compatibilitytest.nupp` pins the whole set.

- Functions, methods, record fields, option keys, and locals: **camelCase**.
  No snake_case in Tecs-controlled identifiers.
- Types (records, enums, aliases) and component definitions: **PascalCase**.
- `SCREAMING_SNAKE_CASE` is for tunables: values that parameterize the
  system and that you would document as configuration (`DEFAULT_PORT`,
  `STARTUP_TIMEOUT`, buffer sizes, magic numbers). A binding that merely
  never reassigns is `const` camelCase.
- Booleans read as predicates: `isRunning`, `hasHoles`, `defaultFixedRotation`.
- New event and data string keys exposed to tooling are namespaced with dots:
  `"myGame.gameState"`.

The camelCase rule is about identifiers this tree declares, and a library's own
names are not among them. `tecs.physics` does not rename Rapier's concepts: a
renamed key is a name that matches nothing the library's own documentation
says.

## Bindings

- `const` is the strong local binding. Use it wherever the value does not
  change, which is almost everywhere.
- Hoist hot standard-library functions into `const` locals in
  performance-sensitive modules: `const sin, cos = math.sin, math.cos`.
- Write the ownership annotation that is true rather than the one that
  compiles. `exclusive` for a value the function may mutate, `borrows` for one
  it only reads, `takes` for one it consumes.
- Use type aliases to keep signatures short: `local type World = ecs.World`.

## Typing discipline

- **`any` is a last resort.** Reach for it only at genuine dynamic
  boundaries: parsed JSON, protected-call results, native crossings, `run_lua`
  style embedding. Cast back to a concrete type at the first opportunity and
  keep the `any` region as small as possible. A helper that takes and
  returns `any` is a design smell; give it a generic or a union instead.
- Prefer **unions** over `any` when the value is one of a known set:
  `export type Sort = "topdown" | "z" | "isometric"`.
- Prefer **generics** over `any` when the type flows through. A type parameter
  that appears in none of a record's fields is not a generic; it is a
  pathological checker cost, and `AGENTS.md` records what it cost once.
- Use `as` casts sparingly and locally, with a comment when the reason is
  not obvious. A cast is an assertion you are making to the compiler; make
  it where the invariant is established, not downstream.
- Mark optional parameters with `?`, and state a record field's optionality in
  its doc comment. Handle `nil` explicitly at every use site and validate
  required fields at construction time. Do not overload `nil` to mean multiple
  things.
- Type every public signature fully, including returns. Multiple returns are
  fine; more than three suggests a record.
- Integer and number are distinct. Use `nupp.math.f32.narrow` and
  `nupp.math.u32.wrap` where a width is part of the contract rather than
  relying on a coincidence of representation.

## Records and types

- **Records** describe concrete data: components, options tables, plain
  structs. Keep them flat; nested records are for genuinely nested data.
  Construct with `new Record(field = value)`.
- Options tables are records or table types with names ending in `Options` or
  `Config` (plain `Config` when a module has one, descriptive like
  `RecordingOptions` when it has several), declared next to the function that
  takes them, every field documented, optionality explicit.
- Interfaces describe capabilities and families: `Component`,
  `ScalarComponent<T>`, `TableComponent<T>`.
- Closed string sets are union aliases rather than a bare `string` field.
- A record field that is private to the module is declared `private`, and the
  documentation generator hides it, so it never becomes part of a contract by
  accident.

## Components

- Declare the value record, then the process-wide definition beside it:

  ```nupp
  --- Gives an entity a velocity in world units per second.
  export record Velocity
      --- Caller-writable. Sets the horizontal speed in world units per second.
      x: number

      --- Caller-writable. Sets the vertical speed in world units per second.
      y: number
  end

  --- The process-wide `Velocity` component definition.
  export const VelocityComponent: ecs.TableComponent<Velocity> = ecs.newComponent({
      name = "Velocity",
      construct = function(x: number?, y: number?): Velocity
          return new Velocity(x = x or 0, y = y or 0)
      end,
      default = function(): Velocity
          return new Velocity(x = 0, y = 0)
      end,
  })
  ```

- **Pick the storage the data actually is.** `ecs.newScalarComponent` holds one
  value per entity and iterates as a flat column. `ecs.newComponent` holds a
  record. `ecs.newTagComponent` holds nothing.
- Tag components beat boolean fields when the flag is stable and queried often:
  queries match archetypes directly instead of scanning. A frequently toggled
  tag moves entities between archetypes every flip; a field is the right call
  for high-frequency toggles.
- Give every component a `name` matching its record name. Queries, MCP and
  snapshots use it, and it is a compatibility surface: say so at the
  declaration.
- A component names what it cannot be meaningful without through its
  requirements, so a spawn that adds it adds those too.
- Keep components as data. Behavior belongs in systems.

## Systems

- Add behavior through plugins, which register components, create queries and
  add systems.
- Every persistent system gets a `name`, and the debugger, MCP tools and
  profiles are unreadable without one. Engine systems are namespaced
  (`"tecs.PollGamepads"`); a game's own follow the same shape.
- A system name is a compatibility surface. An agent selects on it.
- Pick the correct `phase`; do not do render work in `Update` or game logic
  in `Render`. A consumer that has to observe dirty marks runs in `Last`, which
  is the final phase before they clear.
- Gate with `runIf` rather than early-returning inside `run` when the
  condition is state-shaped.
- Systems receive `dt`; never read wall clocks in game logic.
- The host owns the loop. A component exports a session constructor and its
  plugin runs from there; nothing drives frames itself.

## Queries

- Create queries **once, during plugin setup**, and reuse them across the
  system's lifetime. Never create a query inside `run`.
- Iterate archetype-wise and bind columns once per archetype:

  ```nupp
  for candidate, count in moving:iter() do
      local transforms: {ecs.Transform2D} = assert(candidate:getMut(ecs.Transform2D))
      for index = 1, count as integer do
          transforms[index].x = transforms[index].x + dt * 30
      end
  end
  ```

- `archetype:get` for read-only columns, `archetype:getMut` when writing;
  `world:getMut(entity, Component)` when mutating a component fetched by id.
  Skipping the mut variants silently breaks dirty tracking, and calling one in
  a loop that might not write defeats every dirty-gated consumer.
- Query iteration owns no mutation scope or resource. A loop may break, return,
  raise or suspend without cleanup.

## Plugins, resources, and state

- Plugins are the unit of composition: register components, create queries,
  add systems, install observers. Keep each plugin focused enough to test.
- Share globals through `world.resources`, keyed by a typed resource key. No
  globals in game code.
- Entities spawned while a state is on top receive that state's auto-tag;
  spawn deliberately relative to state lifecycles.
- Use observers (`world:observe`) for lifecycle events instead of polling.

## Errors and logging

- An invalid caller argument raises at the call site. An operation that could
  not produce its value returns `nil, reason` or `false, reason`. `AGENTS.md`
  holds the full contract; do not invent a result wrapper to make the two look
  alike.
- `error(message, 0)` for user-actionable failures with a message that says
  what to do next; reserve stack levels for programmer errors, and use the
  level that names the caller's line rather than the helper's.
- Log through `nupp.log.named` with the module's own logger name, not `print`.
  The name is the unit of filtering, so it is a compatibility surface.
- Validate options at construction time with clear messages; do not defer
  failures into the first frame.

## Performance

- Avoid allocations in **measured hot loops** (dense query iteration,
  extraction, storage sync): no closures, table constructors, or varargs
  packing there. Cold per-frame work does not justify pooling; benchmark before
  introducing reusable buffers or pools.
- Prefer numeric `for` over `ipairs` in hot loops; prefer column iteration
  over per-entity component fetches.
- Measure before and after with `nupp task bench` when touching storage,
  rendering or snapshot paths, and read p50 and p95 together.

## Tests

- Suites are Nupp under `tests/`, and discovery reads `tests/*test.nupp`
  without recursing. A suite importing `tecs.internal.*` lives at
  `tests/tecs/<name>test.nupp` with a one-line forwarder where discovery looks.
- One `nupp test` runs them all; `nupp task verify` adds the Rust half
  and the host.
- Do not sleep and hope: drive a deterministic number of frames and assert
  on what they produced.
- A test that reaches a real device is not a test this suite runs. Audio and
  input open nothing until something asks them to, and the suites stay on that
  side of the line.
