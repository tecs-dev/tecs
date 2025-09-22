---
outline: deep
---

# Table Components

A **table component** is a component whose instances are plain Lua tables. Each instance is a distinct table
with the fields you declared, stored in an archetype column alongside the other components on its entity.

Use table components when your data doesn't fit a fixed C struct layout: Love2D handles (textures, fonts,
sounds), variable-length strings, nested Lua tables, or any value that needs Lua reference semantics. For data
that _does_ fit a C struct, reach for [FFI components](/tecs/components/ffi) instead; they share the same
call-site API but back the instance with a C struct in contiguous memory.

Shared constructor rules live in [Component Construction](/tecs/components/construction). This page focuses on
table-specific behavior.

## Creating a table component

Pass a configuration table to `tecs.newComponent` to wire up the metatables and register the component with the
world.

| Property      | Description                                                                                          |
| --------------| -----------------------------------------------------------------------------------------------------|
| `name`        | (**required**) The component name                                                                    |
| `container`   | (**required**) The component type/record                                                             |
| `fields`      | Ordered field names. Codegens the positional base shape and the table-form `.new`. |
| `defaults`    | Default values for `fields`, in matching order (`nil` = no default). Requires `fields`.              |
| `requires`    | Array of components to auto-add alongside this one. See [Auto-dependencies](/tecs/components/#auto-dependencies-with-requires). |
| `init`        | Custom positional init hook. Runs after allocation. Must be paired with `fields` or `new`; otherwise registration errors (so `.new` is never ambiguous). |
| `__call`      | Custom constructor hook. Receives an allocated instance plus the call args. `defaults` are already applied. `init` is not auto-run on this path. |
| `new`         | Custom table-form constructor (`function(data: {string: any}): Component`), called via `Component.new({...})`. Defaults to codegen from `fields` when present. |
| `serialize`   | Custom function to convert the component to a serializable table                                     |
| `deserialize` | Custom function to reconstruct the component from serialized data (receives `world` and data table)  |

## Using `fields` and `defaults`

The recommended path for table components is to declare field names and let Tecs
codegen both the positional `__call` *and* the `.new` table form. Optional
`defaults` fill in static defaults for any field the caller omits; use `nil` for
fields that have no default.

```lua
local record Health is tecs.Component
    value: number
    max: number
    metamethod __call: function(self, value?: number, max?: number): Health
end

tecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"value", "max"},
    defaults = {100, 100},   -- Health() -> {value = 100, max = 100}
})

-- Both forms work
local a: Health = Health(80, 100)
local b: Health = Health.new({ value = 80, max = 100 })
```

::: details Typing `new` config
`Health.new` in the above example is inherited from `tecs.Component`'s base signature
`function(data: {string: any}): self`. Override it with a nested config record when you want
field-by-field type checking on callers:

```lua
local record Health is tecs.Component
    value: number
    max: number

    record HealthConfig
        value: number
        max: number
    end

    metamethod __call: function(self, value?: number, max?: number): Health
    new: function(config: HealthConfig): Health
end

local h: Health = Health.new({ value = 80, max = 100 })  -- checked against HealthConfig
```

The runtime behavior is unchanged. Tecs still codegens `.new` from `fields`. The override only tightens what the
type checker accepts at call sites.
:::

:::details Teal metamethods
Teal records and interfaces define Lua metatable methods using `metamethod`. The `__call` metamethod lets you invoke
the record like a function -- `Position(10, 20)` -- while the `new` method is a regular static field
-- `Position.new({x = 10})`.
:::

## Using `init`

Supply `init` when the positional form needs custom logic `fields` / `defaults` can't express. Table components
are the natural home for this because they routinely wrap non-POD values: a Love2D handle, a validated range, or a
field derived from another.

Because the framework wouldn't know how to unpack a config table into your custom init hook's positional args,
`init` must be paired with either `fields` (Tecs codegens `.new` from the field list) or an explicit `new`.
Registering an `init` without one of those errors immediately: the broken-`.new` footgun is closed by design.

The common case: `fields` alongside an `init` hook that adds validation or derived fields. `fields` defines
the base shape and `.new` unpacking; your `init` refines the allocated instance.

```lua
local record Sprite is tecs.Component
    texture: love.graphics.Texture
    metamethod __call: function(self, texture: love.graphics.Texture): Sprite
end

tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    fields = {"texture"},
    init = function(instance: Sprite, texture: love.graphics.Texture)
        assert(texture, "Sprite requires a texture")
        instance.texture = texture
    end,
})

local a: Sprite = Sprite(img)                  -- positional, runs init
local b: Sprite = Sprite.new({ texture = img }) -- table form, unpacks then runs init
```

Reach for an explicit `new` (next section) when the table shape doesn't map cleanly to positional args, for
example a config with many optional fields where positional calls would be unergonomic.

## Custom `__call`

Use config `__call` when the call-site arguments are semantic inputs rather than
a direct field list. Tecs allocates the table instance, applies `defaults`, then
invokes your hook as `__call(instance, ...)`. It does not auto-run `init` after
that; call `Component.init(...)` yourself if you want to share logic.

## Overriding `.new`

Supply `new` when you want callers to have an ergonomic `Component.new({...})` form with named fields and
defaults. You'll typically pair it with a custom `init` so both shapes share the same defaults and
validation.

```lua
local record Light is tecs.Component
    radius: number
    intensity: number
    cookie: integer

    record LightConfig
        radius: number
        intensity: number
        cookie: integer
    end

    metamethod __call: function(self, radius?: number, intensity?: number): Light
    new: function(config: LightConfig): Light
end

tecs.newComponent({
    name = "Light",
    container = Light,
    fields = {"radius", "intensity"},
    defaults = {200, 1.0},
    init = function(instance: Light)
        instance.cookie = 0
    end,
    new = function(c: {string: any}): Light
        local cfg = c as LightConfig
        return {
            radius = cfg.radius or 200,
            intensity = cfg.intensity or 1.0,
            cookie = cfg.cookie or 0,
        }
    end,
})

local a: Light = Light(200, 1.5)              -- positional
local b: Light = Light.new({ cookie = 3 })    -- table form, named fields
```

## Where are component hooks?

::: details You're looking for query callbacks...
If you're coming from a [Flecs](https://www.flecs.dev/flecs/) background, you might wonder why Tecs doesn't
offer component hooks that fire when a component is added, removed, or replaced on an entity.
[Query callbacks](/tecs/queries/callbacks) cover the same use cases and fit the mutation model better.

1. **Query callbacks batch; component hooks can't.**
   A component hook fires once per entity, even in bulk paths like `world:batchSpawn`. Query callbacks fire once per
   contiguous row range, and the common bulk work (allocating GPU slots, sizing external buffers, registering with a
   physics world) amortizes cleanly across the batch.

2. **Query callbacks match on signatures, not single components.**
   "Fire when an entity has both `Sprite` and `Transform`" is one query with `include = {Sprite, Transform}`.
   With component hooks you'd need to register on both components and manually coordinate a flag to reach the same
   behavior.
3. **`onReplace` style hooks are incompatible with the mutation model.**
   Tecs components are mutable in place (both table and FFI). The hot write pattern is direct column access:
   ```lua
   positions[row].x = positions[row].x + velocities[row].vx * dt
   ```

   That's one or two cycles per field in a tight loop over SoA columns. Hooking value changes would either force
   every write through a setter (defeating the purpose of exposing the column), or insert a branch on every column
   assignment. Tecs doesn't track interior mutability for that reason.
4. **Dirty tracking tells you when things change.**
   When you do need "tell me when `Health` changed," use [dirty tracking](/tecs/components/dirty-tracking). It's
   the batching answer to `onReplace`: a write through `archetype:getMut(Health)` flips a per-archetype,
   per-component bit (idempotent, so N writes collapse to one mark) and a sync system drains the set once per
   frame. What an `onReplace` hook would spread across N handler calls becomes one pass over dirty columns, at
   the consumer's own cadence.
5. **One abstraction, not two.**
   Query callbacks already exist, are run in a deferred state, already handle the matching and scheduling story, and
   already thread into the world's commit process. Adding component hooks would duplicate the observer spine with a
   second, weaker mechanism.
:::
