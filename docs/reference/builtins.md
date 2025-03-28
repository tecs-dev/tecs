---
outline: deep
---

# Builtins

Tecs provides various builtin plugins, components, and events. These builtins are registered with every
[World](/reference/world) by default.

## Components

### Name component

Provides a name for an entity.

**Properties:**

- `value`: The string value of the name.

**Teal type:**

```lua
record Name is components.Component
    value: string

    --- Creates a new Name component.
    ---
    --- @param value The name of the entity.
    --- @return the created name component.
    metamethod __call: function(self, value: Name | string): Name
end
```

**Example:**

```lua
local tecs = require("tecs")

local entity = world:spawn(
    tecs.builtins.Name("Phreddy")
)
```

### ChildOf relationship component

Defines a parent/child relationship between two entities. When the parent entity is despawned, the child is
automatically despawned.

**Teal type:**

```lua
type ChildOf = components.Relationship
```

**Example:**

```lua
-- Spawn the parent.
local parent = world:spawn()

-- Spawn the child and associate it with the parent.
local child = world:spawn(
    tecs.builtins.ChildOf(parent)
)

-- Use a command to defer the despawn until after the spawns are committed.
world:command(function()
    -- Despawn the parent, which causes the child to also be despawned.
    world:despawn(parent)
end)
```

### Emitter component

Gives an entity an entity-specific event emitter allowing entities to emit events and observers to subscribe to
events emitted by a specific entity.

This is the component that's retrieved or given to an entity when using
`world:getEntityEmitter()`.

:::tip
If you know an entity is going to emit events, then you can assign an `Emitter` to the entity when it's
spawned rather than waiting for `world:getEntityEmitter()` to add the component. This is a minor optimization
to prevent the entity from unnecessarily moving archetypes.
:::

**Teal type:**

```lua
--- Gives an entity an event dispatcher for handling events.
---
--- Note that this component _is_ an Emitter.
record Emitter is components.Component, events.Emitter
    --- Create a new dispatcher.
    ---
    --- @param consumer Function that gets the dispatcher and can add event observers.
    --- @return the created dispatcher component.
    metamethod __call: function(self, consumer?: function(d: events.Emitter)): Emitter
end
```

**Example:**

```lua
local entity = world:spawn(
    tecs.builtins.Emitter()
)
```

### Transform component

**Teal type:**

Provides the position and layer of an entity. You can use this component if it works for your game, or ignore
it if not.

```lua
record Transform is components.Component
    --- The x coordinate of the entity.
    x: number

    --- The y coordinate of the entity.
    y: number

    --- The z coordinate of the entity.
    z: number

    --- The layer of the entity (or nil if you don't use layers).
    layer: integer

    --- Creates a new Transform component.
    ---
    --- @param xOrValue The x position or full transform data if passing a table.
    --- @param y The y position.
    --- @param z The z position.
    --- @param layer The layer.
    --- @return the created transform component.
    metamethod __call: function(
        self,
        xOrValue?: Transform | number,
        y?: number,
        z?: number,
        layer?: integer
    ): Transform
end
```

**Examples:**

```lua
-- Using positional arguments
world:spawn(
    tecs.builtins.Transform(10, 11, 1, 2) -- x, y, z, layer
)

-- Using table argument
world:spawn(
    tecs.builtins.Transform({
        x = 10,
        y = 11,
        z = 1,
        layer = 2
    })
)
```

:::info Performance
Transform uses FFI storage for optimal performance and includes component recycling.
:::

### TTL component

Automatically despawns an entity when the TTL, or "time to live" reaches zero. Tecs automatically
adds a sytem that tracks entities with a TTL and despawns them.

**Teal type:**

```lua
--- Despawns an entity when the TTL reaches zero.
record TTL is components.Component
    --- The total amount of time the entity had to live.
    startingTime: number

    --- The remaining time the entity has to live.
    remaining: number

    --- Compute the percentage of completion as a number between 0 and 1.
    percentComplete: function(self): number

    --- Create a new TTL component.
    ---
    --- @param remaining The amount of time the entity has to live.
    --- @return the created TTL component.
    metamethod __call: function(self, remaining: number): TTL
end
```

**Example:**

```lua
world:spawn(
    -- Despawn the entity after 10 seconds.
    tecs.builtins.TTL(10)
)

```

## Events

### OnSpawn event

An event emitted from an entity emitter when the entity is spawned. The event is only emitted if the entity
has a `tecs.builtins.Emitter` component and there are observers for the event.

::: info Event timing
The `OnSpawn` event is emitted after the entity has been fully created:
- All components have been added to the entity
- The entity has been added to queries
- `world:isAlive(entity)` returns `true`
:::

**Teal type:**

```lua
--- An event emitted when a specific entity is spawned.
record OnSpawn is events.Event
    entity: integer

    --- Create a new OnSpawn event.
    metamethod __call: function(self, entity: integer): OnSpawn
end
```

**Usage:**

```lua
local entity = world:spawn(
    tecs.builtins.Emitter(function(emitter)
        emitter:observe(tecs.builtins.OnSpawn, function(event)
            print("Entity spawned: " .. event.entity)
        end)
    end)
)
```

### OnDespawn event

An event emitted from an entity emitter when the entity is despawned. The event is only emitted if the entity
has a `tecs.builtins.Emitter` component.

::: info Event timing
The `OnDespawn` event is emitted at the beginning of the despawn process. When this event fires:
- `world:isAlive(entity)` returns `false`
- Entity components are still accessible via `world:get()`
- The entity has not yet been removed from queries
:::

**Teal type:**

```lua
--- An event emitted when a specific entity is despawned.
record OnDespawn is events.Event
    entity: integer

    --- Create a new OnDespawn event.
    metamethod __call: function(self, entity: integer): OnDespawn
end
```

**Example:**

```lua
local emitter = world:getEntityEmitter(entityId)
emitter:observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    -- Entity is no longer "alive" but components are still accessible
    local pos = world:get(e.entity, Position)
    if pos then
        spawnExplosionAt(pos.x, pos.y)
    end
    print("Entity " .. e.entity .. " was despawned")
end)
```

## States

### Debug state

A built-in state used to enable debug mode for a game.

**Teal type:**

```lua
--- The built-in debug state machine.
record Debug is tecs.DefaultedStates<Values>
    enum Values
        "off"
        "on"
    end
    default: Values
end

Debug.default = "off"
```

**Example:**

Set the state to debug:

```lua
world:setState(tecs.builtins.Debug, "on")
```

Run a system only if in debug mode:

```lua{6-9}
world:addSystem({
    phase = tecs.phases.Render,
    run = function(dt: number, w: tecs.World)
        print("In debug mode")
    end,
    runIf = function(dt: number, w: tecs.World)
        -- Only run the system if Debug is set to "on".
        return w:inState(tecs.builtins.Debug, "on")
    end
})
```