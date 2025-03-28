---
outline: deep
---

# Tecs Reference

This is the complete API reference for Tecs, a type-safe Entity Component System for Lua.

Tecs was built from the ground-up to support static typing with Teal and to be as fast as possible, providing nearly
C-like speed in a Lua-based game framework.

## Getting Started

```lua
local tecs = require("tecs")
```

Tecs uses a single-import design where everything is accessed through the main `tecs` module.

## Core Factory Functions

These functions create the primary building blocks of your ECS application:

### newWorld()

```lua
local world = tecs.newWorld()
```

Creates a new [World](/reference/world) that manages entities, components, and systems. The World is the hub of a game.

### newComponent()

```lua
local Position = tecs.newComponent({
    name = "Position",
    container = PositionType,
    constructor = function(x, y) return {x = x, y = y} end
})
```

Creates a new [Component](/reference/components) for storing entity data.

### newTagComponent()

```lua
local Selected = tecs.newTagComponent({name = "Selected"})
```

Creates an efficient [tag component](/reference/components#creating-tag-components) with no data.

### newFFIComponent()

```lua
local Velocity = tecs.newFFIComponent({
    name = "Velocity",
    container = VelocityType,
    fields = {{"x", "float"}, {"y", "float"}}
})
```

Creates a high-performance [FFI component](/reference/ffi-components) using C structs for optimal memory layout.

### newRelationship()

```lua
local ChildOf = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true
})
```

Creates a [Relationship](/reference/relationships) component that links entities together.

### newTagRelationship()

```lua
local Follows = tecs.newTagRelationship({
    name = "Follows",
    exclusive = true
})
```

Creates a high-performance [tag relationship](/reference/relationships#creating-tag-relationships-high-performance)
that only stores the target entity ID using efficient FFI storage.

### newFFIRelationship()

```lua
local FastFollows = tecs.newFFIRelationship({
    name = "FastFollows",
    container = FastFollowsType,
    fields = {{"delay", "float"}, {"maxDistance", "float"}}
})
```

Creates a high-performance [FFI relationship](/reference/relationships#creating-ffi-relationships-high-performance-with-data)
that stores relationship data in FFI structs for optimal performance.

### newKey()

```lua
local FONT: tecs.Key<love.graphics.Font> = tecs.newKey()
```

Creates a typed key for storing [resources](/reference/world#resources) in the world.

### newEmitter()

```lua
local emitter = tecs.newEmitter()
```

Creates a new [event emitter](/reference/events#emitters) for broadcasting events to listeners.

### newEvent()

```lua
tecs.newEvent(PlayerDamaged, function(damage: number): PlayerDamaged
    return {damage = damage}
end)
```

Configures a custom [event](/reference/events) with table-based storage.

### newFFIEvent()

```lua
tecs.newFFIEvent(FastEvent, {
    {"damage", "float"},
    {"entityId", "int32_t"}
})
```

Configures a high-performance [FFI event](/reference/events#tecs-newffielvent) with C struct backing.

### newStateContainer()

```lua
local container = tecs.newStateContainer()
```

Creates an independent [state container](/reference/states#advanced-custom-state-containers) for advanced use cases.

## Submodules

These modules provide specialized functionality and are accessed through `tecs.moduleName`:

### [tecs.builtins](/reference/builtins)

Built-in components and events that provide common ECS functionality:
- `tecs.builtins.Transform` - Gives position and transformation to an entity
- `tecs.builtins.Name` - Gives a name to an entity
- `tecs.builtins.ChildOf` - Sets up parent-child relationships
- `tecs.builtins.OnDespawn` - Event emitted when an entity is despawned

### [tecs.phases](/reference/phases)

Execution phases that organize when systems run:
- `tecs.phases.Startup` - Run once at world startup
- `tecs.phases.Update` - Main game logic updates
- `tecs.phases.FixedUpdate` - Fixed timestep updates
- `tecs.phases.Render` - Rendering and presentation
- ... and more. See [tecs.phases](/reference/phases) for the full set of phases

### [tecs.logging](/reference/logging)

Hierarchical logging system:
- `tecs.logging.getLogger()` - Get named loggers
- `tecs.logging.rootLogger` - Default logger instance

## Entity IDs

Tecs uses a simple, monotonically increasing integer for entity IDs. Each entity receives the next available ID
starting from 1.

```lua
local entity1 = world:spawn() -- ID: 1
local entity2 = world:spawn() -- ID: 2
local entity3 = world:spawn() -- ID: 3

world:despawn(entity2)
local entity4 = world:spawn() -- ID: 4 (IDs are not reused)
```

::: details Why doesn't Tecs use packed or generational IDs?

- **No ID exhaustion**: Tecs just auto-increments 53-bit integers, which provides 9 quadrillion possible IDs.
  At 1 million spawns/second, it would take 285 years to run out of IDs.
- **No stale references**: Since IDs are never reused, a despawned entity's ID will never suddenly refer to a
  different entity. This provides the same safety as generational IDs but without the overhead.
- **It's fast**: simple IDs avoid expensive bitwise operations and the need to recycle IDs with free lists. Bitwise
  operations in LuaJIT are fast, but they aren't C++ level, single-instruction fast. And free-list management isn't
  free.
- **Archetypes are still dense**: Tecs uses a hashmap style table to find which archetype an entity belongs to
  (a fast O(1) lookup). Archetypes, however, use dense arrays for fast iteration, insertion, and deletion by giving
  entities a row.
- **Relationships don't need them**: Relationships in Tecs are just components that have a target, and optionally other
  data associated with them. Baking relationship information into component IDs rather than using a dedicated type
  would also erode type safety which is a major goal Tecs.
:::