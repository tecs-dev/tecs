---
description: "Component overview with world get, getMut, set, remove, has, requires, and transient"
outline: deep
---

# Components

Components hold entity data. A system binds component columns from each
matching archetype, reads through `get`, and takes writable columns through
`getMut`:

```teal
local Transform2D <const> = tecs.Transform2D
local movers <const> = world:newQuery({
    include = {Transform2D, Velocity},
})

world:addSystem({
    name = "game.Move",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        for archetype, length in movers:iter() do
            local transforms <const> = archetype:getMut(Transform2D)
            local velocities <const> = archetype:get(Velocity)

            for row = 1, length do
                transforms[row].x = transforms[row].x
                    + velocities[row].x * dt
                transforms[row].y = transforms[row].y
                    + velocities[row].y * dt
            end
        end
    end,
})
```

`getMut` marks the `Transform2D` column dirty. The renderer and other
incremental consumers use that mark to skip unchanged columns.

Component values belong to callers. Callers may replace them with `world:set`
or mutate their fields through `getMut`; Tecs owns the storage and dirty marks
around those values.

## Storage choices

| Kind                                                | Use                                                          |
| --------------------------------------------------- | ------------------------------------------------------------ |
| [Table](/modules/ecs/components/table-components)   | Strings, nested tables, opaque handles, and other Lua values |
| [FFI](/modules/ecs/components/ffi)                  | Fixed-size numeric fields in contiguous C structs            |
| [Scalar](/modules/ecs/components/scalar-components) | One `number`, `boolean`, or `string` per entity              |
| [Tag](/modules/ecs/components/tag-components)       | Presence with no per-entity value                            |

The engine uses the same factories. `Transform2D`, `Sprite`, `Tint`, `Material`,
`Clip`, and `PointLight2D` use FFI storage; `Renderable2D` uses table-component
registration as a presence marker.

## Entity access

`world:get(entity, Component)` returns the component or `nil`. A scalar
component returns its raw value:

```teal
local transform <const> = world:get(entity, tecs.Transform2D)
local name <const> = world:get(entity, tecs.ecs.Name)
```

Call `world:getMut` before an in-place write:

```teal
local transform <const> = world:getMut(entity, tecs.Transform2D)
if transform then
    transform.x = transform.x + 10
end
```

Do not call `getMut` at a site that might only read. It declares mutation
intent and defeats dirty-gated work even when no value changes.

An FFI reference obtained through `world:get` remains writable because LuaJIT
cannot make cdata const. If code writes through that reference, it must call
`world:markComponentDirty(entity, Component)` explicitly.

A spawn reserves an ID but does not place the entity until the next pipeline
barrier. `world:get` and `world:getMut` return `nil` for that staged entity.
Pass its initial values to `world:spawn` instead.

## Adding and removing components

Pass instances to `world:spawn` and `world:set`:

```teal
local entity <const> = world:spawn(
    tecs.ecs.Name("Frank"),
    tecs.Transform2D(100, 200)
)

world:set(entity, tecs.ecs.Name("Grace"))
world:remove(entity, tecs.ecs.Name)
```

`world:has(entity, Component)` tests presence. Relationship containers and
instances add any-target and specific-target checks; see
[Relationships](/modules/ecs/relationships/).

Adding or removing a component changes the entity's archetype, so those calls
always stage until a pipeline barrier. [Structural
transactions](/modules/ecs/world#structural-transactions) covers the visibility
rules.

## Component dependencies {#auto-dependencies-with-requires}

`requires` declares components that must accompany another component. Tecs
adds the full transitive closure in one archetype transition:

```teal
local record Velocity is tecs.ecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Velocity
end

tecs.ecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"},
    },
    defaults = {0, 0},
    requires = {tecs.Transform2D},
})

local entity <const> = world:spawn(Velocity(10, 20))
assert(world:has(entity, tecs.Transform2D))
```

A `requires` entry may hold a component type, which Tecs calls with no
arguments, or a component instance shared by every automatic addition.
`newComponent`, `newFFIComponent`, `newScalarComponent`, `newTagComponent`,
and both relationship factories accept the option.

`tecs.ecs.RelativeTransform2D` requires `tecs.Transform2D`, so a relative
transform and the world transform it feeds enter the same archetype together.

Use [query callbacks](/modules/ecs/queries/callbacks) for work that must run when a
signature starts or stops matching.

## Transient state

Set `transient = true` on components and relationships that hold runtime
projections such as native handles or caches. Snapshots omit those columns but
keep their entities. Rebuild the omitted values from durable components after
load.

`transient` and a custom `serialize` function conflict, so registration rejects
that combination. [Component serialization](/modules/ecs/components/serialization)
covers codecs and migrations.
