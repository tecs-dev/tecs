---
description: "Component overview with world get, getMut, set, remove, has, requires, and transient"
outline: deep
---

# Components

Components hold entity data. A system binds component columns from each
matching archetype, reads through `get`, and takes writable columns through
`getMut`:

```nupp
@derive(tecs.ecs.Component)
local struct Velocity
    x: number = 0
    y: number = 0
end

local Transform2D = tecs.ecs.Transform2D
local movers = world:newQuery({
    include = {Transform2D, Velocity},
})

world:addSystem({
    name = "game.Move",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        for archetype, length in movers:iter() do
            local transforms = assert(archetype:getMut(Transform2D))
            local velocities = assert(archetype:get(Velocity))
            unsafe do
                for row = 1, length as integer do
                    transforms[row].x = transforms[row].x
                        + velocities[row].x * dt
                    transforms[row].y = transforms[row].y
                        + velocities[row].y * dt
                end
            end
        end
    end,
})
```

`getMut` marks the `Transform2D` column dirty. Incremental consumers such as
hierarchy composition use that mark to skip unchanged work.

Component values belong to callers. Callers may replace them with `world:set`
or mutate their fields through `getMut`; Tecs owns the storage and dirty marks
around those values.

## Storage choices

Derive `tecs.ecs.Component` on the value declaration. A `struct` selects native
columns and a `record` selects managed columns. Pass `new Velocity(...)` to
mutations and `Velocity` itself to queries, reads, removals and bulk defaults.
The component name defaults to the module-qualified declaration name. Pin a
persisted identity with `@component(name = "game.Velocity")`; moving or renaming
an unpinned declaration changes its snapshot identity.

`tecs.ecs.newComponent(Velocity, options)` configures requirements, codecs or
custom factories, or gives the same value layout a distinct component identity.
It does not choose a different physical representation. Configure the default
identity before using the declaration in a world.

Generic helpers accept `Type<T>` with `T is tecs.ecs.ComponentValue`. Helpers
that inspect edges can use `T is tecs.ecs.RelationshipPayload`. These bounds keep
the stored value type intact without importing an internal module.

| Kind                           | Use                                                    |
| ------------------------------ | ------------------------------------------------------ |
| Native struct                  | Fixed-layout numeric data in contiguous native columns |
| [Record](table-components.md)  | Structured values, strings, nested records and handles |
| [Scalar](scalar-components.md) | One number, boolean or string per entity               |
| [Tag](tag-components.md)       | Presence with no per-entity value                      |

The engine uses the same storage selection. Transform, tint, shape material, camera,
lighting, animation, audio state, physics values, and numeric UI components use
native structs with storage selected by their declarations. `Renderable2D` is a tag. Text, styles,
Tiled metadata and other components with strings or managed collections remain
records.

Native component columns are one-based `T[?]` arrays, indexed inside `unsafe do`
using the query's row count. Reads return live row references; reacquire them
after publication, compaction, clear or restore. Native assignment copies a
value into the row rather than sharing a managed object.

Nupp owns struct methods and derives. Built-in native values derive
`nupp.derive.Debug` and `nupp.derive.Serde`. A prepared Serde codec can encode a
borrowed row directly. That generic encoding describes the struct's own fields;
world snapshots still use Tecs's component codecs, including name-based asset
resolution and transient-state handling.

## Entity access

`world:get(entity, Component)` returns the component or `nil`. A scalar
component returns its raw value:

```nupp
local transform = world:get(entity, tecs.ecs.Transform2D)
local name = world:get(entity, tecs.ecs.Name)
```

Call `world:getMut` before an in-place write:

```nupp
local transform = world:getMut(entity, tecs.ecs.Transform2D)
if transform then
    transform.x = transform.x + 10
end
```

Do not call `getMut` at a site that might only read. It declares mutation
intent and defeats dirty-gated work even when no value changes.

A reference obtained through `world:get` does not mark its column dirty. If code writes through that reference, it must call
`world:markComponentDirty(entity, Component)` explicitly.

A spawn reserves an ID but does not place the entity until the next pipeline
barrier. `world:get` and `world:getMut` return `nil` for that staged entity.
Pass its initial values to `world:spawn` instead.

## Adding and removing components

Pass instances to `world:spawn` and `world:set`:

```nupp
local entity = world:spawn(
    tecs.ecs.Name("Frank"),
    tecs.ecs.Transform2D(100, 200)
)

world:set(entity, tecs.ecs.Name("Grace"))
world:remove(entity, tecs.ecs.Name)
```

`world:has(entity, Component)` tests presence, including a relationship
definition. Read a relationship value to inspect its target; see
[Relationships](/ecs/relationships/index.md).

Adding or removing a component changes the entity's archetype, so those calls
always stage until a pipeline barrier. [Structural
transactions](/ecs/world.md#structural-transactions) covers the visibility
rules.

## Component dependencies {#auto-dependencies-with-requires}

`requires` declares components that must accompany another component. Tecs
adds the full transitive closure in one archetype transition:

```nupp
local Moving = tecs.ecs.newTagComponent({
    name = "Moving",
    requires = {tecs.ecs.Transform2D},
})
local entity = world:spawn(Moving)
world:commit()
assert(world:has(entity, tecs.ecs.Transform2D))
```

A requirement names a component definition. Automatic addition uses that
component's default constructor. `RelativeTransform2D` requires `Transform2D`,
so a relative transform and the world transform it feeds enter together.

## Transient state

Set `transient = true` on components and relationships that hold runtime
projections such as native handles or caches. Snapshots omit those columns but
keep their entities. Rebuild the omitted values from durable components after
load. [Save games](../save-games.md) covers custom `save` and `load` callbacks.
