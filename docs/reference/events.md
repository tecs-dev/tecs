---
outline: deep
---

# Events

Tecs provides a lightweight, type-safe event system. Events allow decoupled systems to communicate.

## Core concepts

The events system is built around three core concepts:

* **Events**: Type-safe objects that carry information.
* **Emitters**: Objects that can broadcast events.
* **Listeners**: Functions that respond to events.

## Example: react when entity is despawned

Tecs emits a built-in event, `tecs.builtins.OnDespawn`, when an entity is despawned. You can listen for
this event to do things like clean up any references to the entity, spawn an explosion animation,
play a sound effect, etc.

```lua
local tecs = require("tecs")

-- Spawn an entity and get the entity ID.
local entity = world:spawn()

-- Get or create an event emitter for the entity.
local emitter = world:getEntityEmitter(entity)

-- Listen for when the entity is despawned.
emitter:observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)
```

## Entity emitter

You can get an emitter for any entity using `world:getEntityEmitter(entityId)`:

```lua
local entityId = world:spawn()
local emitter = world:getEntityEmitter(entityId)
```

Calling this method will create and assign an emitter to the entity if it doesn't already have one.
This can be done immediately after spawning an entity, even before the entity is committed in the next system update.

## World is an emitter

The `World` in Tecs is an event emitter. You can use the World to emit and observe events globally across your game.

```lua
world:observe(MyEvent, function(e: MyEvent)
    print("Got MyEvent")
end)

world:emit(MyEvent("hi"))
```

## Event functions

Event management functions are available directly on the `tecs` module:

```lua
local tecs = require("tecs")
```

### tecs.newEmitter

Creates a new event emitter.

```lua
function tecs.newEmitter(): Emitter
```

**Returns:**

- A new event emitter instance

**Example:**

```lua
local tecs = require("tecs")
local emitter = tecs.newEmitter()
```


### tecs.newEvent

Configures an event to have an appropriate `__call`-based constructor.

```lua
function tecs.newEvent<E is Event>(
    event: E,
    constructor: function(...: any): E
)
```

**Parameters:**

- `event`: The event instance to configure
- `constructor`: A function that creates an instance of the event

**Example:**

```lua
-- Define the PlayerDamaged record as an event.
local record PlayerDamaged is tecs.Event
    damage: number

    --- Create a new PlayerDamaged event.
    metamethod __call: function(self, damage: number): self
end

-- Have Tecs set up the metatable, assign type, etc.
tecs.newEvent(PlayerDamaged, function(damage: number): PlayerDamaged
    return {damage = damage}
end)

-- Now we can create events like this:
local damageEvent = PlayerDamaged(10)
```


### tecs.newFFIEvent

Configures an FFI event with arena allocation and C struct backing for optimal performance.

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

-- Configure as FFI event with C struct backing
tecs.newFFIEvent(DamageEvent, {
    {"damage", "float"},
    {"entityId", "int32_t"},
    {"damageType", "int32_t"}
}, "Game_DamageEvent")

-- Usage is identical to regular events
local damage = DamageEvent(15.5, 1234, 2)
```

**Performance Benefits:**

FFI events provide significant performance improvements for high-frequency events:

- Zero-allocation after warmup via arena allocation
- Cache-friendly C struct layout
- Fast integer-based type dispatch
- Automatic memory management

**FFI Fallback Behavior:**

FFI events automatically fall back to table-based events when FFI is unavailable:

- **LuaJIT with FFI**: Uses arena allocation with C structs for optimal performance
- **Lua 5.1+ without FFI**: Uses table-based events with proper type defaults

**When to Use FFI Events:**

Use `newFFIEvent` for:

- High-frequency events (damage, movement, collisions)
- Events with only primitive data types
- Performance-critical event systems

::: tip FFI event compatibility
FFI events cannot be used if the event contains: Lua objects, userdata, functions, or anything incompatible with
LuaJIT FFI.
:::

## Events

An event is any record that implements the `tecs.Event` interface, which requires the event to have a `type` field
that references itself.

```lua
interface Event
    --- The unique ID of the event.
    eventId: integer
end
```

> See [tecs.newEvent](#tecs-newevent) for creating events.

## Emitters

An emitter is an object that can broadcast events to registered listeners.

> See [tecs.newEmitter](#tecs-newemitter) for creating emitters.

### Emitter Interface

```lua
interface Emitter
    --- Observes an event synchronously by type.
    observe: function<E is Event>(self, eventType: E, callback: function(event: E), id?: string)

    --- Observes an event synchronously by type, at most once.
    observeOnce: function<E is Event>(self, eventType: E, callback: function(event: E))

    --- Stops observing an event by type.
    stopObserving: function<E is Event>(self, eventType: E, callback: function(event: E) | string)

    --- Checks if the world has any observers for the given event type.
    hasObservers: function<E is Event>(self, eventType: E): boolean

    --- Emits an event to all observers of the event type.
    emit: function<E is Event>(self, event: E)

    --- Remove all observers.
    reset: function(self)
end
```

### Emitter Methods

#### observe

Subscribes to an event by type.

```lua
function Emitter:observe<E is Event>(
    eventType: E,
    callback: function(event: E),
    id?: string
)
```

**Parameters:**

- `eventType`: The type of event to observe
- `callback`: The callback to call when the event is emitted
- `id`: Optional ID used to name the event so it can be removed by name

**Example:**

```lua
-- Basic usage
emitter:observe(PlayerDamaged, function(event)
    print("Player took " .. event.damage .. " damage!")
end)

-- With optional ID
emitter:observe(PlayerDamaged, function(event)
    updateHealthUI(event.damage)
end, "ui-updater")
```

#### observeOnce

Subscribes to an event by type, at most once.

```lua
function Emitter:observeOnce<E is Event>(
    eventType: E,
    callback: function(event: E)
)
```

**Parameters:**

- `eventType`: The type of event to observe
- `callback`: The callback to call when the event is emitted

**Example:**

```lua
emitter:observeOnce(GameStarted, function(event)
    playStartAnimation()
end)
```

#### stopObserving

Stops observing an event by type.

```lua
function Emitter:stopObserving<E is Event>(
    eventType: E,
    callbackOrId: function(event: E) | string
)
```

**Parameters:**

- `eventType`: The type of event to stop observing
- `callbackOrId`: Either the callback function to remove, or the ID string that was provided when observing

**Example:**

Stop observing events by passing the callback function:

```lua
-- Store the callback function
local handleDamage = function(event)
    print("Damage: " .. event.damage)
end

emitter:observe(PlayerDamaged, handleDamage)

-- Later, stop observing by passing the same function reference
emitter:stopObserving(PlayerDamaged, handleDamage)
```

Stop observing events by passing the ID:

```lua
-- Provide an ID when observing
emitter:observe(PlayerDamaged, updateUI, "ui-update")

-- Later, stop observing by passing the ID
emitter:stopObserving(PlayerDamaged, "ui-update")
```

#### hasObservers

Checks if the emitter has any observers for the given event type. This can be used to check if
anything is listening to an event before creating it.

```lua
function Emitter:hasObservers<E is Event>(eventType: E): boolean
```

**Parameters:**

- `eventType`: The type of event to check for observers

**Returns:**

- `boolean`: `true` if the emitter has observers for the event type

**Example:**

```lua
if emitter:hasObservers(ExplosionEvent) then
    -- Create the event and emit it...
end
```

#### emit

Emits an event to all observers of the event type.

```lua
function Emitter:emit<E is Event>(event: E)
```

**Parameters:**

- `event`: The event instance to emit

**Example:**

```lua
-- Create and emit in one line
emitter:emit(PlayerDamaged(15))

-- Or create then emit
local explosion = ExplosionEvent(100, 200, 50)
emitter:emit(explosion)
```

#### reset

Removes all observers from the emitter.

```lua
function Emitter:reset()
```

**Example:**

```lua
-- Remove all event observers
emitter:reset()
```