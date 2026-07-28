---
description: "Lua-table-backed components via newComponent with fields, init, custom __call, and new"
outline: deep
---

# Table Components

A **table component** is a component whose instances are plain Lua tables. Each instance is a distinct table
with the fields you declared, stored in an archetype column alongside the other components on its entity.

Use table components when your data doesn't fit a fixed C struct layout: opaque runtime handles,
variable-length strings, nested Lua tables, or any value that needs Lua reference semantics. For data that
_does_ fit a C struct, reach for [FFI components](/ecs/components/ffi) instead; they share the same call-site
API but back the instance with a C struct in contiguous memory, which is what the extractor reads when it
builds a frame.

Shared constructor rules live in [Component Construction](/ecs/components/construction). This page focuses on
table-specific behavior.

## Creating a table component

Pass a configuration table to `tecs.newComponent` to wire up the metatables and register the component.

```teal
function tecs.newComponent<C is Component>(options: ComponentOptions<C>): C
```

| Property      | Description                                                                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`        | (**required**) The component name. Registering a name twice errors.                                                                                      |
| `container`   | (**required**) The component type/record.                                                                                                                |
| `fields`      | Ordered field names. Codegens the positional base shape and the table-form `.new`.                                                                       |
| `defaults`    | Default values for `fields`, in matching order (`nil` = no default). Requires `fields`.                                                                  |
| `requires`    | Array of components to auto-add alongside this one. See [Auto-dependencies](/ecs/components/#auto-dependencies-with-requires).                           |
| `init`        | Custom positional init hook. Runs after allocation. Must be paired with `fields` or `new`; otherwise registration errors (so `.new` is never ambiguous). |
| `__call`      | Custom constructor hook. Receives an allocated instance plus the call args. `defaults` are already applied. `init` is not auto-run on this path.         |
| `new`         | Custom table-form constructor (`function(data: {string: any}): C`), called via `Component.new({...})`. Defaults to codegen from `fields` when present.   |
| `serialize`   | Custom function converting the component to a serializable table. Mutually exclusive with `transient`.                                                   |
| `deserialize` | Custom function reconstructing the component from serialized data (receives `world` and the data table).                                                 |
| `transient`   | If `true`, omit this component from snapshots. Use for runtime-only handles/caches. Mutually exclusive with `serialize`.                                 |

**Returns:** the registered component container.

Only `name` and `container` are required. The engine's `Renderable` is declared with exactly those two: it
carries no fields, and marking an entity as contributing geometry is all it does.

```teal
local record Renderable is Component end

ecs.newComponent({
    name = "Renderable",
    container = Renderable,
})
```

## Using `fields` and `defaults`

The recommended path for table components is to declare field names and let Tecs codegen both the positional
`__call` _and_ the `.new` table form. Optional `defaults` fill in static defaults for any field the caller
omits; use `nil` for fields that have no default.

```teal
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

Instances carry a metatable whose `__index` is the container, so `instance.componentType` and the other
container-level fields resolve without being stamped on every instance.

::: details Typing `new` config
`Health.new` in the above example is inherited from `tecs.Component`'s base signature
`function(data: {string: any}): self`. Override it with a nested config record when you want field-by-field
type checking on callers:

```teal
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

The runtime behavior is unchanged. Tecs still codegens `.new` from `fields`. The override only tightens what
the type checker accepts at call sites.
:::

::: details Teal metamethods
Teal records and interfaces define Lua metatable methods using `metamethod`. The `__call` metamethod lets you
invoke the record like a function, as in `Position(10, 20)`, while `new` is a regular static field accessed as
`Position.new({x = 10})`.
:::

## Using `init`

Supply `init` when the positional form needs custom logic `fields` / `defaults` can't express. Table
components are the natural home for this because they routinely wrap non-POD values: an opaque handle, a
validated range, or a field derived from another.

Because the framework wouldn't know how to unpack a config table into your custom init hook's positional args,
`init` must be paired with either `fields` (Tecs codegens `.new` from the field list) or an explicit `new`.
Registering an `init` without one of those errors immediately: the broken-`.new` footgun is closed by design.

The common case: `fields` alongside an `init` hook that adds validation or derived fields. `fields` defines
the base shape and `.new` unpacking; your `init` refines the allocated instance.

```teal
local record Inventory is tecs.Component
    slots: {string}
    capacity: integer
    metamethod __call: function(self, slots: {string}, capacity?: integer): Inventory
end

tecs.newComponent({
    name = "Inventory",
    container = Inventory,
    fields = {"slots", "capacity"},
    defaults = {nil, 10},
    init = function(instance: Inventory)
        if instance.slots == nil then
            error("Inventory requires a slots table")
        end
        if #instance.slots > instance.capacity then
            error("Inventory has more slots than capacity")
        end
    end,
})

local a: Inventory = Inventory({"sword"})                       -- positional, runs init
local b: Inventory = Inventory.new({ slots = {"sword"} })       -- table form, unpacks then runs init
```

Reach for an explicit `new` (next section) when the table shape doesn't map cleanly to positional args, for
example a config with many optional fields where positional calls would be unergonomic.

## Custom `__call` and overriding `.new`

Use config `__call` when the call-site arguments are semantic inputs rather than a direct field list. Tecs
allocates the table instance, applies `defaults`, then invokes your hook as `__call(instance, ...)`. It does
not auto-run `init` after that; call `Component.init(...)` yourself if you want to share logic.

Supply `new` alongside it when the table form should not be a mechanical unpack of the positional one. Tecs
applies the instance metatable to whatever your `new` returns, so the result behaves like any other instance
of the component.

The engine's `ParticleEmitter` pairs both. It has one argument worth naming, the effect, and a handful of
scale factors a caller almost never sets, so a positional list would be mostly `nil`s. Both entry points funnel
into the same initializer:

```teal
ecs.newComponent({
    name = "ParticleEmitter",
    container = ParticleEmitter,
    requires = { Transform },
    __call = function(item: ParticleEmitter, options: EmitterOptions)
        initEmitter(item, options)
    end,
    new = function(data: {string: any}): ParticleEmitter
        local item <const> = {} as ParticleEmitter
        initEmitter(item, data as EmitterOptions)
        return item
    end,
})

-- ParticleEmitter({ effect = sparks })
```

## Where are component hooks?

::: details You're looking for query callbacks...
If you're coming from a [Flecs](https://www.flecs.dev/flecs/) background, you might wonder why Tecs doesn't
offer component hooks that fire when a component is added, removed, or replaced on an entity.
[Query callbacks](/ecs/queries/callbacks) cover the same use cases and fit the mutation model better.

1. **Query callbacks batch; component hooks can't.**
   A component hook fires once per entity, even in bulk paths like `world:batchSpawn`. Query callbacks fire
   once per contiguous row range, and the common bulk work (allocating GPU slots, sizing external buffers,
   registering with a physics world) amortizes cleanly across the batch.
2. **Query callbacks match on signatures, not single components.**
   "Fire when an entity has both `Sprite` and `Transform`" is one query with `include = {Sprite, Transform}`.
   With component hooks you'd need to register on both components and manually coordinate a flag to reach the
   same behavior.
3. **`onReplace` style hooks are incompatible with the mutation model.**
   Tecs components are mutable in place (both table and FFI). The hot write pattern is direct column access:

   ```teal
   positions[row].x = positions[row].x + velocities[row].vx * dt
   ```

   That's one or two cycles per field in a tight loop over SoA columns. Hooking value changes would either
   force every write through a setter (defeating the purpose of exposing the column), or insert a branch on
   every column assignment. Tecs doesn't track interior mutability for that reason.

4. **Dirty tracking tells you when things change.**
   When you do need "tell me when `Health` changed," use [dirty tracking](/ecs/components/dirty-tracking).
   It's the batching answer to `onReplace`: a write through `archetype:getMut(Health)` flips a per-archetype,
   per-component bit (idempotent, so N writes collapse to one mark) and a sync system drains the set once per
   frame. What an `onReplace` hook would spread across N handler calls becomes one pass over dirty columns, at
   the consumer's own cadence.
5. **One abstraction, not two.**
   Query callbacks already exist, already handle the matching story, and already thread into the world's
   commit process. Adding component hooks would duplicate the observer spine with a second, weaker mechanism.
   :::
