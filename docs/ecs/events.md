---
description: "Address-based ECS events: observe, emit, hasObservers, newEvent, newFFIEvent, and the MessageBus router"
outline: deep
---

# Events

Tecs has a typed event system with centralized, address-based routing. Events let systems and plugins that do
not know about each other communicate: one side emits at an address, the other observes at the same address.

This page covers the ECS event system, which is what `world:emit` and `world:observe` route. The engine's
platform events, the window, keyboard, mouse, gamepad and file-drop stream, are a separate module that delivers
one ECS event type per kind onto the same bus at address `0`; see [`events`](/modules/events).

## Core concepts

The system centers on three ideas:

- **Events**: typed records or FFI structs that carry information, registered once with `tecs.ecs.newEvent` or
  `tecs.ecs.newFFIEvent`.
- **Addresses**: integer routing destinations. `0` is world level; an entity ID addresses that entity.
- **Observers**: callbacks registered at an address for one event type.

## Address types

| Address | Description                                  | Example                                 |
| ------- | -------------------------------------------- | --------------------------------------- |
| `0`     | World-level events, for global communication | `world:observe(0, GamePaused, handler)` |
| `> 0`   | Events for one entity, by ID                 | `world:observe(id, OnDespawn, handler)` |

## Example: react when an entity despawns

Tecs emits a builtin event, [`OnDespawn`](/ecs/builtins#ondespawn-event), when an entity is despawned. Observe it
to clean up references, spawn an effect, or play a sound. Observers are registered from a game's entry plugin,
next to its systems, so both are on the world and both run inside the crash guard:

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.components.Transform

return tecs.application.create({
    plugin = function(world: tecs.World, app: tecs.application.Application)
        world:observe(0, tecs.ecs.builtins.OnDespawn, function(e: tecs.ecs.builtins.OnDespawn)
            -- Still readable: the row is removed at commit, not here.
            local transform <const> = world:get(e.entity, Transform)
            if transform then
                spawnDebrisAt(world, transform.x, transform.y)
            end
        end)
    end,
})
```

## An observer is not a system

An observer runs at the moment of the emit, inside whatever the emitter was doing, rather than at a point in
the frame it chose. That has consequences worth knowing before reaching for one:

- A `world:emit` from a system runs its observers before that `emit` call returns, in the emitting system's
  phase, inside whatever [deferred scope](/ecs/queries/#mutations-during-iteration) the emitter holds.
- Platform events at address `0` are delivered as they arrive from the host, which is ahead of `world:update`.
  So a platform observer fires before every system in the frame the event belongs to, outside every phase: no
  fixed step, and none of the pause or state gating a system gets from its phase and its `runIf`.

A reaction that needs phase order, the fixed step or state gating folds the event into something a system reads
instead. That is what [`Input`](/modules/input) does with the whole platform stream: it consumes it into state,
and systems read that state in phase.

## World-level events

Use address `0` for events that are not tied to a specific entity.

```teal
world:observe(0, MyEvent, function(e: MyEvent)
    print("Got MyEvent")
end)

world:emit(0, MyEvent, "hi")
```

## Entity-level events

Use the entity ID as the address for entity-specific events. When the entity despawns, every observer registered
at its address is removed, so a per-entity subscription does not leak into the next entity that recycles the
slot.

```teal
local entityId <const>: integer = world:spawn()

world:observe(entityId, tecs.ecs.builtins.OnDespawn, function(e: tecs.ecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)
```

## World methods

These methods are available on every `World`.

| Method                                           | Description                                                  |
| ------------------------------------------------ | ------------------------------------------------------------ |
| [`world:observe`](#world-observe)                | Subscribe to an event at a world or entity address.          |
| [`world:emit`](#world-emit)                      | Emit an event instance, or construct and emit an event type. |
| [`world:hasObservers`](#world-has-observers)     | Whether any observer exists for an address and event type.   |
| [`world:stopObserving`](#world-stop-observing)   | Remove a callback or a named observer.                       |
| [`world:clearObservers`](#world-clear-observers) | Remove every observer at one address.                        |

### world:observe {#world-observe}

Registers an observer for an event type at an address.

```teal
function World:observe<T is Event>(
    address: integer,
    event: T,
    callback: function(event: T),
    id?: string
)
```

**Parameters:**

- `address`: address to observe. `0` for world-level events, an entity ID for entity events.
- `event`: the event type to observe.
- `callback`: called when a matching event is emitted at that address.
- `id`: optional string ID, so the observer can be removed by name later.

**Example:**

```teal
world:observe(0, MyCustomEvent, function(e: MyCustomEvent)
    print("Got MyCustomEvent")
end)

world:observe(entityId, tecs.ecs.builtins.OnDespawn, function(e: tecs.ecs.builtins.OnDespawn)
    print("Entity despawned: " .. e.entity)
end)
```

### world:emit {#world-emit}

Emits an event to every observer at an address.

```teal
function World:emit(address: integer, eventOrType: Event, ...: any)
```

**Parameters:**

- `address`: address to emit to. `0` for world-level events, an entity ID for entity events.
- `eventOrType`: an event instance to dispatch as-is, or an event type followed by constructor arguments.
- `...`: constructor arguments, when `eventOrType` is an event type.

**Example:**

```teal
world:emit(0, MyCustomEvent)

-- Passing the type plus constructor args lets the world skip construction
-- entirely when no observer is registered.
world:emit(entityId, DamageReceived, 15)
```

### world:hasObservers {#world-has-observers}

Whether any observer exists for an event type at an address. Reach for it when computing the payload is
expensive; you do not need it merely to avoid constructing the event, because
`world:emit(address, EventType, ...)` already checks first.

```teal
function World:hasObservers<T is Event>(address: integer, event: T): boolean
```

**Example:**

```teal
if world:hasObservers(entityId, DamageReceived) then
    world:emit(entityId, DamageReceived, expensiveDamagePayload())
end
```

### world:stopObserving {#world-stop-observing}

Stops observing an event type at an address.

```teal
function World:stopObserving<T is Event>(
    address: integer,
    event: T,
    observer: function(T) | string
)
```

**Parameters:**

- `address`: address to stop observing.
- `event`: the event type.
- `observer`: the callback function, or the string `id` passed to `world:observe`.

Passing a function removes every registration of that function for the type at that address; passing an `id`
removes the first observer registered under it. A removal requested while the bus is dispatching is deferred
until the dispatch unwinds, so an observer can unsubscribe itself from inside its own callback.

**Example:**

```teal
world:stopObserving(0, MyEvent, myCallback)
world:stopObserving(entityId, tecs.ecs.builtins.OnDespawn, "cleanup-handler")
```

### world:clearObservers {#world-clear-observers}

Clears every observer at an address. Entity addresses are cleared automatically when the entity despawns, so
this is for addresses you manage yourself.

```teal
function World:clearObservers(address: integer)
```

## Event functions

Event registration functions live directly on the `tecs` module. An event type must be registered exactly once;
registering the same type twice raises an error.

### tecs.ecs.newEvent

Configures an event record so it has a `__call`-based constructor and a unique `eventId`.

```teal
function tecs.ecs.newEvent<E is Event>(event: E)
```

**Parameters:**

- `event`: the event type to configure.
- `event.init`: an optional function that populates an instance in place. Assign it before calling `newEvent`.
  When absent, the constructor allocates an instance and sets no fields.

**Example:**

```teal
local record PlayerDamaged is tecs.Event
    damage: number
    source: string

    --- Create a new PlayerDamaged event.
    metamethod __call: function(self, damage: number, source: string): self
end

-- `init` receives a pre-allocated instance and mutates it in place.
PlayerDamaged.init = function(e: PlayerDamaged, damage: number, source: string)
    e.damage = damage
    e.source = source
end
tecs.ecs.newEvent(PlayerDamaged)

-- A direct constructor always allocates a fresh instance.
local damageEvent <const>: PlayerDamaged = PlayerDamaged(10, "fire")

-- For the optimized emission path, let the world construct lazily.
world:emit(0, PlayerDamaged, 10, "fire")
```

### Constructor versus emit

The two construction paths differ in allocation:

- **Direct constructor**, `PlayerDamaged(10, "fire")`: always allocates a fresh, independent instance. Use it
  when you need to hold the event past the current emit, or when you are dispatching through a standalone
  `MessageBus`.
- **`world:emit(address, EventType, ...)`**: the fast path. It checks for observers before constructing
  anything, then builds the instance from the world's own pooled backing storage, so a hot emission loop
  allocates nothing.

::: warning
Do not retain a reference to the instance an observer receives from `world:emit`. The world returns that backing
storage to its pool as soon as the emit completes, and the next emit of the same type reuses it. Copy the fields
you need.
:::

### tecs.ecs.newFFIEvent

Configures an event backed by a C struct, allocated from the emitting world's leased FFI slice on the
`world:emit` path.

```teal
function tecs.ecs.newFFIEvent<E is Event>(
    event: E,
    fields: {{string, string}},
    structName?: string
)
```

**Parameters:**

- `event`: the event type to configure.
- `fields`: field definitions as `{ {"name", "type"}, ... }`, where the type is a C type name.
- `structName`: optional struct name. One is generated when it is omitted.

Field names must be valid C identifiers and must be unique. `eventId` and `typeId` are reserved: Tecs writes
them itself and rejects a definition that names either. The field type string is emitted into the generated
struct declaration; the types used across this repository are `float`, `double`, `int32_t`, `uint32_t`,
`uint8_t`, `uint16_t` and `bool`.

An FFI event that does not define `init` gets a generated positional initializer that assigns the fields in the
order they were declared, so the constructor's argument order matches the `fields` order.

**Example:**

```teal
local record DamageEvent is tecs.Event
    damage: number
    entityId: integer
    damageType: integer

    -- The constructor matches the order of the FFI fields.
    metamethod __call: function(
        self,
        damage: number,
        entityId: integer,
        damageType: integer
    ): self
end

-- Use `"double"` for any field holding an entity ID. A packed ID carries
-- generation bits and does not fit in int32, and truncation would produce
-- a garbage ID on the receiving side.
tecs.ecs.newFFIEvent(DamageEvent, {
    {"damage", "float"},
    {"entityId", "double"},
    {"damageType", "int32_t"}
}, "Game_DamageEvent")

local damage <const>: DamageEvent = DamageEvent(15.5, 1234, 2)

-- The optimized path, same as for table events.
world:emit(0, DamageEvent, 15.5, 1234, 2)
```

::: tip FFI event compatibility
An FFI event's fields live in a C struct, so it cannot carry Lua tables, strings, functions or userdata. Use
`tecs.ecs.newEvent` for events that need Lua values.
:::

The builtin [`OnSpawn`](/ecs/builtins#onspawn-event) and [`OnDespawn`](/ecs/builtins#ondespawn-event) events are
FFI events, each carrying a single `entity` field declared as `double` for exactly that reason.

## MessageBus

`world:observe` and `world:emit` delegate to the world's `MessageBus`, the address-keyed router that holds the
observers and dispatches events. Each world owns one. `tecs.ecs.newMessageBus()` creates a standalone bus when you
want routing without a world.

```teal
function tecs.ecs.newMessageBus(): MessageBus
```

| Method                                                | Description                                                                                                                                                                                         |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bus:observe(address, eventType, observer, id?)`      | Subscribe to an event type at an address. The optional `id` allows unsubscribing by name.                                                                                                           |
| `bus:observeOnce(address, eventType, observer)`       | Subscribe; the observer removes itself after it fires once.                                                                                                                                         |
| `bus:stopObserving(address, eventType, observerOrId)` | Unsubscribe a callback, or an `id`, from an event type at an address.                                                                                                                               |
| `bus:emit(address, event)`                            | Dispatch an already-constructed instance to the observers at the address, returning early when there are none. Construct the event first, or use `world:emit` for the lazy construct-and-skip path. |
| `bus:hasObservers(address, eventType)`                | Whether any observer exists for that event type at the address.                                                                                                                                     |
| `bus:clearAddress(address)`                           | Remove every observer at one address. This is what an entity despawn uses.                                                                                                                          |
| `bus:clearEntityObservers()`                          | Remove every per-entity observer, that is every address except the global `0`, preserving global subscriptions. Used by `world:clearEntities`.                                                      |
| `bus:reset()`                                         | Remove all observers, global ones included. Full teardown.                                                                                                                                          |
