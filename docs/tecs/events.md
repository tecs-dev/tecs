---
outline: deep
---

# Events

Tecs provides a lightweight, type-safe event system with centralized address-based routing. Events allow decoupled
systems to communicate.

## Core concepts

The events system centers on three concepts:

* **Events**: Type-safe objects that carry information.
* **Addresses**: Integer routing destinations for events (`0` for world-level, entity IDs for entity events).
* **Observers**: Functions that respond to events at specific addresses.

## Address types

Events are routed through integer addresses:

| Address Type   | Description                                   | Example                                     |
| -------------- | --------------------------------------------- | ------------------------------------------- |
| `0`            | World-level events for global communication   | `world:observe(0, GamePaused, ...)`         |
| `>0`           | Events for an entity by ID                    | `world:observe(entityId, OnDespawn, ...)`   |

## Example: react when entity despawns

Tecs emits a built-in event, `tecs.builtins.OnDespawn`, when you despawn an entity. Listen for this
event to clean up references to the entity, spawn an explosion animation, play a sound effect, etc.

```lua
local tecs = require("tecs")

-- Spawn an entity and get the entity ID.
local entity: integer = world:spawn()

-- Listen for when the entity is despawned.
world:observe(entity, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)
```

## World-level events

Use address `0` for events that aren't tied to a specific entity:

```lua
-- Observe world-level events
world:observe(0, MyEvent, function(e: MyEvent)
    print("Got MyEvent")
end)

-- Emit world-level events
world:emit(0, MyEvent, "hi")
```

## Entity-level events

Use the entity ID as the address for entity-specific events:

```lua
local entityId: integer = world:spawn()

-- Observe events on this specific entity
world:observe(entityId, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)

-- When the entity is despawned, all observers on its address are automatically cleaned up
```

## Event functions

Event management functions are available directly on the `tecs` module:

```lua
local tecs = require("tecs")
```

### tecs.newEvent

Configures an event to have an appropriate `__call`-based initialization path.

```lua
function tecs.newEvent<E is Event>(event: E)
```

**Parameters:**

- `event`: The event instance to configure
- `event.init`: A function that populates an event instance (mutates in place, does not return)

**Example:**

```lua
-- Define the PlayerDamaged record as an event.
local record PlayerDamaged is tecs.Event
    damage: number
    source: string

    --- Create a new PlayerDamaged event.
    metamethod __call: function(self, damage: number, source: string): self
end

-- Have Tecs set up the metatable, assign type, etc.
-- `.init` receives a pre-allocated instance and mutates it.
PlayerDamaged.init = function(e: PlayerDamaged, damage: number, source: string)
    e.damage = damage
    e.source = source
end
tecs.newEvent(PlayerDamaged)

-- Direct constructors always allocate a fresh instance:
local damageEvent: PlayerDamaged = PlayerDamaged(10, "fire")

-- For the optimized emission path, let the world construct lazily:
world:emit(0, PlayerDamaged, 10, "fire")
```

### Constructor vs Emit

Direct constructors always allocate a fresh instance:

```lua
local record SensorReading is tecs.Event
    x: number
    y: number
    z: number

    metamethod __call: function(self, x: number, y: number, z: number): self
end

-- Enable pooling for zero-allocation emissions
SensorReading.init = function(e: SensorReading, x: number, y: number, z: number)
    e.x, e.y, e.z = x, y, z
end
tecs.newEvent(SensorReading)

local a = SensorReading(1, 2, 3)
local b = SensorReading(4, 5, 6)
assert(a ~= b)
```

For the fast path, emit the event type plus constructor args:

```lua
world:emit(0, SensorReading, 1, 2, 3)
```

In that form, the world:
- checks for observers before constructing anything
- reuses world-local backing storage for repeated emissions

Do not retain references to instances received from `world:emit(address, EventType, ...)` across later emits of the same type on that world.

### tecs.newFFIEvent

Configures an FFI event with C struct backing and slice-scoped arena allocation for optimized world emission.

```lua
function tecs.newFFIEvent<E is Event>(
    event: E,
    fields: {{string, string}},
    structName?: string
)
```

**Parameters:**

- `event`: The event type to configure
- `fields`: Field definitions in format `{ {"name", "type"}, ...}` where type uses C FFI types
- `structName`: Optional struct name (auto-generated if not provided)

**FFI Field Types:**

Common FFI field types you can use:
- `int32_t`, `uint32_t` - 32-bit signed/unsigned integers
- `int64_t`, `uint64_t` - 64-bit signed/unsigned integers
- `float`, `double` - floating point numbers
- `bool` - boolean values
- `char[N]` - fixed-size character arrays (e.g., `char[64]`)

**Example:**

```lua
-- Define an FFI event for high-frequency damage events
local record DamageEvent is tecs.Event
    damage: number
    entityId: integer
    damageType: integer

    -- Constructor must match the order of the FFI fields.
    metamethod __call: function(
        self,
        damage: number,
        entityId: integer,
        damageType: integer
    ): self
end

-- Configure as FFI event with C struct backing. Use `"double"` (not
-- `"int32_t"`) for any field that holds an entity id: packed ids can
-- exceed int32 range once the generation bits are populated, and
-- truncation would produce garbage ids on the receiving side.
tecs.newFFIEvent(DamageEvent, {
    {"damage", "float"},
    {"entityId", "double"},
    {"damageType", "int32_t"}
}, "Game_DamageEvent")

-- Usage is identical to regular events
local damage: DamageEvent = DamageEvent(15.5, 1234, 2)
```

Direct FFI constructors allocate a fresh cdata instance each call. For the optimized path, emit the event type through
the world:

```lua
world:emit(0, DamageEvent, 15.5, 1234, 2)
```

That path checks for observers first and allocates from the emitting world's leased FFI slice in the global event manager.

::: tip FFI event compatibility
FFI events cannot contain Lua objects, userdata, functions, or anything incompatible with LuaJIT FFI. Use
`tecs.newEvent` for events that need Lua values and prefer `world:emit(address, EventType, ...)` for the optimized path.
:::
