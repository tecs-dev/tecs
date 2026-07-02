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

```teal
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

```teal
-- Observe world-level events
world:observe(0, MyEvent, function(e: MyEvent)
    print("Got MyEvent")
end)

-- Emit world-level events
world:emit(0, MyEvent, "hi")
```

## Entity-level events

Use the entity ID as the address for entity-specific events:

```teal
local entityId: integer = world:spawn()

-- Observe events on this specific entity
world:observe(entityId, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)

-- When the entity is despawned, all observers on its address are automatically cleaned up
```

## World methods

These methods are available on every `World`.

| Method | Description |
| ------ | ----------- |
| [`world:observe`](#world-observe) | Subscribe to an event at a world or entity address. |
| [`world:emit`](#world-emit) | Emit an event instance or construct-and-emit an event type. |
| [`world:hasObservers`](#world-has-observers) | Check whether any observer exists for an address and event type. |
| [`world:stopObserving`](#world-stop-observing) | Remove a callback or named observer. |
| [`world:clearObservers`](#world-clear-observers) | Remove all observers at one address. |

### world:observe {#world-observe}

Registers an observer for an event at a specific address.

```teal
function World:observe<E is Event>(
    address: integer,
    eventType: E,
    observer: function(E),
    id?: string
)
```

**Parameters:**

- `address`: Address to observe (`0` for world-level events, entity ID for entity events).
- `eventType`: Event type to observe.
- `observer`: Callback called when the event is emitted.
- `id`: Optional string ID for later removal.

```teal
world:observe(0, MyCustomEvent, function(e: MyCustomEvent)
    print("Got MyCustomEvent")
end)

world:observe(entityId, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity despawned: " .. e.entity)
end)
```

### world:emit {#world-emit}

Emits an event to all observers at a specific address.

```teal
function World:emit(address: integer, eventOrType: Event, ...: any)
```

**Parameters:**

- `address`: Address to emit to (`0` for world-level events, entity ID for entity events).
- `eventOrType`: Event instance to emit, or an event type followed by constructor args.
- `...`: Constructor args, when `eventOrType` is an event type.

```teal
world:emit(0, MyCustomEvent)

-- Passing the type plus constructor args lets the world skip construction
-- when no observers are registered.
world:emit(entityId, DamageReceived, 15)
```

### world:hasObservers {#world-has-observers}

Checks if any observers exist for an event at an address. This is useful when computing the payload is expensive; you
usually do not need it just to avoid event construction if you use `world:emit(address, EventType, ...)`.

```teal
function World:hasObservers<E is Event>(address: integer, eventType: E): boolean
```

```teal
if world:hasObservers(entityId, DamageReceived) then
    world:emit(entityId, DamageReceived, expensiveDamagePayload())
end
```

### world:stopObserving {#world-stop-observing}

Stops observing an event at an address.

```teal
function World:stopObserving<E is Event>(
    address: integer,
    eventType: E,
    observer: function(E) | string
)
```

**Parameters:**

- `address`: Address to stop observing.
- `eventType`: Event type.
- `observer`: Callback function or string ID provided to `world:observe`.

```teal
world:stopObserving(0, MyEvent, myCallback)
world:stopObserving(entityId, tecs.builtins.OnDespawn, "cleanup-handler")
```

### world:clearObservers {#world-clear-observers}

Clears all observers for an address. Entity-address observers are cleared automatically when that entity despawns.

```teal
function World:clearObservers(address: integer)
```

## Event functions

Event management functions are available directly on the `tecs` module:

```teal
local tecs = require("tecs")
```

### tecs.newEvent

Configures an event to have an appropriate `__call`-based initialization path.

```teal
function tecs.newEvent<E is Event>(event: E)
```

**Parameters:**

- `event`: The event instance to configure
- `event.init`: A function that populates an event instance (mutates in place, does not return)

**Example:**

```teal
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

### Constructor vs emit

The two construction paths differ in allocation:

- **Direct constructor** (`PlayerDamaged(10, "fire")`): always allocates a fresh, independent instance. Use it
  when you need to hold onto the event past the current emit.
- **`world:emit(address, EventType, ...)`**: the fast path. It checks for observers before constructing
  anything, then reuses world-local backing storage across repeated emissions of the same type, so a hot
  emission loop allocates nothing.

```teal
world:emit(0, PlayerDamaged, 10, "fire")
```

::: warning
Don't retain a reference to the instance an observer receives from `world:emit` past that callback; the
world reuses the backing storage on the next emit of the same type.
:::

### tecs.newFFIEvent

Configures an FFI event with C struct backing and slice-scoped arena allocation for optimized world emission.

```teal
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

```teal
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

```teal
world:emit(0, DamageEvent, 15.5, 1234, 2)
```

That path checks for observers first and allocates from the emitting world's leased FFI slice in the global event manager.

::: tip FFI event compatibility
FFI events cannot contain Lua objects, userdata, functions, or anything incompatible with LuaJIT FFI. Use
`tecs.newEvent` for events that need Lua values and prefer `world:emit(address, EventType, ...)` for the optimized path.
:::

## MessageBus

`world:observe` / `world:emit` delegate to the world's `MessageBus`, the address-keyed router that
holds observers and dispatches events. Each world owns one. `tecs.newMessageBus()` creates a
standalone bus if you want routing without a world.

| Method | Description |
|--------|-------------|
| `bus:observe(address, EventType, callback, id?)` | Subscribe to an event type at an address. Optional `id` lets you unsubscribe by name. |
| `bus:observeOnce(address, EventType, callback)` | Subscribe; the observer is removed after it fires once. |
| `bus:stopObserving(address, EventType, callbackOrId)` | Unsubscribe a callback (or `id`) from an event type at an address. |
| `bus:emit(address, EventType, ...)` | Construct and dispatch an event to observers at the address. Skips construction when there are none. |
| `bus:hasObservers(address, EventType)` | Whether any observer exists for that event type at the address. |
| `bus:clearAddress(address)` | Remove every observer at one address. Used when an entity despawns. |
| `bus:clearEntityObservers()` | Remove every per-entity observer (all addresses except global `0`), preserving global subscriptions. Used by `world:clearEntities`. |
| `bus:reset()` | Remove all observers, global ones included. Full teardown. |
