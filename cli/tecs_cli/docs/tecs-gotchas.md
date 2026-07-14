# Tecs / Teal gotchas

Sharp edges that make `tecs check` fail or cause silent runtime bugs — read before debugging a confusing type error or a component that "doesn't update".

## Teal / LuaJIT typing

- **`love.math.random` returns `number`, not `integer`.** Assigning it to an `integer` field or
  using it as a table key fails type-check. Wrap it: `math.floor(love.math.random(0, n))`. Same for
  any arithmetic that must land in an `integer` slot.
- **No `//` operator.** The gen target is Lua 5.1 (LuaJIT); integer floor-division `//` does not
  exist. Use `math.floor(a / b)`.
- **Optional record fields can't be marked with `?`.** Only function parameters take `?`. Document
  a field's optionality in its doc comment, handle `nil` at every use site, and validate required
  fields at construction time.
- **`any` is a last resort.** Prefer unions (`string | Timeline`) or generics
  (`function<T>(...): T`). Cast back to a concrete type as soon as possible with a local `as`.

## Dirty tracking (the "my change doesn't render" bug)

- `world:get(id, C)` and `archetype:get(C)` are **read-only** — writing through them silently
  bypasses dirty tracking, so GPU/render and reactive systems never see the change.
- Use `world:getMut(id, C)` / `archetype:getMut(C)` at every site where you intend to **write**.
  This returns the column *and* marks it dirty.

## Components

- **Tags are added by passing the container**, e.g. `world:spawn(Transform(0,0), Dead)` where
  `local Dead = tecs.newTagComponent{...}`. Non-tag components must be *constructed*:
  `world:spawn(..., gfx.Color(1,0,0,1))`.
- Every component needs a `name` matching its record — queries, MCP, and snapshots key on it.
- Don't mix storage: if any field must hold a Lua table/string/object, it's a `newComponent`
  (table) component, not `newFFIComponent`.
- Frequently toggled flags: prefer a boolean field over a tag. A tag flip moves the entity between
  archetypes each time; stable, queried flags are the good tag case.

## Systems and queries

- **Never create a query inside `run`.** Build it once in the plugin and reuse it.
- Give every system a `name` — the debugger, MCP tools, and profiler are unreadable without one.
- Do game logic in `Update`/`FixedUpdate`, render work in render phases — not the other way around.
- Systems get `dt`; never read a wall clock in game logic.

## Loop ownership

- `tecs2d.run` owns the loop. Do not define `love.update` / `love.draw` / `love.keypressed`
  yourself — add systems and read `tecs2d.input` instead.

See also: `tecs docs tecs-style`, `tecs docs tecs-ecs`.
