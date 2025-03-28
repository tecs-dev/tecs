---
outline: deep
---

# Components

A component is a plain data object attached to an entity. Components describe traits like position, velocity,
or health, and are the building blocks of game state.

## Getting components

Components of an entity are accessed using `world:get`.

```lua
local name = world:get(entityId, tecs.builtins.Name)
```

Notice that the component type, `tecs.builtins.Name` was provided to the `get` method. Tecs is strongly typed with
Teal, and the `get` method is generic over the component type. So in the above example, the return value of
`get` is an instance of `tecs.builtins.Name` or `nil` if not found.

::: tip Access components with queries
You typically won't need to get one-off components like this and should instead use [queries](/reference/queries).
:::

## Setting components

Components are set on entities using `world:set`.

```lua
world:set(entityid, tecs.builtins.Name("Frank"))
```

Components can be set when spawning an entity.

```lua
world:spawn(
    tecs.builtins.Name("Frank"),
    tecs.builtins.Position(100, 200)
)
```

## Removing components

Components are removed from entities using `world:remove`.

```lua
world:remove(entityId, tecs.builtins.Name)
```

## Deferred mutations

When mutating or spawning entities inside systems, the mutation is deferred until after the system completes.
This ensures the world is consistent as the system is processing entities. So changes to an entity may not be
immediately reflected when calling `world:get`.

## Creating a component

To create a component, first define a Teal record. Here we define the `Sprite` component.

```lua
local record Sprite is tecs.Component
    texture: love.graphics.Texture
    metamethod __call: function(self, love.graphics.Texture): self
end
```

:::details Teal metamethods
Lua metatable methods are defined in Teal records and interfaces using `metamethod`.
The above record defines a `__call` metamethod that's used to create an instance of a `Sprite`
component. The `__call` metamethod allows you to call the record like a function:

```lua
local sprite = Sprite(love.graphics.newImage("cactus.png"))
```
:::

Next, pass a configuration table to `tecs.newComponent` to wire up the necessary metatables to make it a component.
`tecs.newComponent` handles wiring up the metatables and other required component properties.
The configuration table contains:

| Property | Description |
|----------|-------------|
| `name` (**required**) | The component name |
| `container` (**required**) | The component type/record |
| `constructor` | Function that creates component instances |
| `storage` | Custom [storage](#component-storage) implementation |
| `onAdd` | [Hook](#component-hooks) called when component is added to an entity |
| `onRemove` | [Hook](#component-hooks) called when component is removed from an entity |

Creating a `Sprite` component:

```lua
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    constructor = function(texture: love.graphics.Texture): Sprite
        return {texture = texture}
    end
})
```

Now you can set the `Sprite` component on the entity.

```lua
world:set(entityId, Sprite(love.graphics.newImage("cactus.png")))
```

### Creating tag components

*Tag* components are components with no data; their presence alone carries meaning. Use `tecs.newTagComponent` to
create a tag component:

```lua
local Selected = tecs.newTagComponent("Selected")
local Disabled = tecs.newTagComponent("Disabled")
```

You can then use tag components just like regular components:

```lua
world:set(entityId, Selected)
world:remove(entityId, Disabled)
```

::: tip Tags are efficient
Tag components are more memory efficient than normal components for this purpose because they use a bitset storage
internally.
:::

### Advanced: using a custom component metatable

An advanced and rare use case for components is using a custom metatable for a component. This is used when a
component "isa" another type. For example, the `tecs.builtins.Emitter` component isa `tecs.Emitter`.
When the `tecs.newComponent` method sees that the table returned from the component constructor has a custom
metatable, it will create an appropriate component instance that uses the desired metatable and also still
uses the component container type too.

The following code shows how the `tecs.builtins.Emitter` component is created:

```lua
tecs.newComponent({
    name = "Emitter",
    container = builtins.Emitter,
    constructor = function(consumer?: function(events.Emitter)): builtins.Emitter
        local e = tecs.newEmitter()
        if consumer then
            consumer(e)
        end
        return e as builtins.Emitter
    end
})
```

## Component bundles

Bundles provide a convenient way to define reusable sets of components that can be spawned together.

### Creating a bundle

Use `tecs.newBundle()` create a new bundle using a builder pattern. Bundles support two types of components:

- **Required components** using `require()`: must be provided when using the bundle
- **Optional components** using `add()`: have default factories but can be overridden

```lua
local playerBundle = tecs.newBundle()
    :require(tecs.builtins.Position)
    :require(Health)
    :add(tecs.builtins.Velocity, function()
        return tecs.builtins.Velocity(0, 0)  -- Optional with default
    end)
    :add(Sprite, function()
        return Sprite("player.png")  -- Optional with default
    end)
    :build()
```

Above, `Position` and `Health` are essential and must be customized per entity, while `Velocity` and `Sprite`
have reasonable defaults.

### Creating entities from bundles

Bundles create the variadic set of components for an entity that can be provided directly to `world:spawn`:

```lua
world:spawn(playerBundle(
    tecs.builtins.Position(100, 200),
    Health(80)
    -- Velocity and Sprite use defaults
))
```

You can also override optional components or add additional ones:

```lua
world:spawn(playerBundle(
    tecs.builtins.Position(50, 50),    -- Required
    Health(500),                       -- Required
    Sprite("boss.png"),                -- Override optional default
    Boss()                             -- Add additional component
))
```

## Component hooks

Component hooks allow you to run code when components are added or removed from entities. This enables powerful
patterns like automatic dependencies, computed values, and cleanup logic.

:::details Performance benefits
Component hooks provide a significant performance advantage by avoiding archetype transitions. When hooks
automatically add dependent components, all changes happen in the same mutation batch before the entity is
inserted into its final archetype. This means the entity only transitions once to its final archetype,
rather than multiple times as each component is added individually.
:::

### Available hooks

- **`onAdd<C>`**: Called when a component of type `C` is added to an entity
- **`onRemove<C>`**: Called when a component of type `C` is removed from an entity

Both hooks receive the entity ID and a `ChangeView` that allows you to inspect and modify the entity's components
in the same mutation batch.

### The changes API

`ChangeView` provides methods to interact with an entity's components during a mutation:

```lua
-- Get a component (checks both current state and pending changes)
local position = view:get(Position)

-- Add or update a component
view:set(Position(100, 200))

-- Remove a component
view:remove(Velocity)

-- Check if a component exists or will exist
if view:has(Health) then
    -- ...
end
```

### Using component hooks for dependencies

Component hooks make it easy to implement automatic dependencies between components. For example, ensuring that
`Velocity` always has `Position`, or that `Health` always has `MaxHealth`.

```lua
local Position = tecs.newComponent({
    name = "Position",
    container = PositionType,
    constructor = function(x, y)
        return {x = x or 0, y = y or 0}
    end
})

local Velocity = tecs.newComponent({
    name = "Velocity",
    container = VelocityType,
    constructor = function(vx, vy)
        return {vx = vx or 0, vy = vy or 0}
    end,
    onAdd = function(self: VelocityType, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Ensure Position exists when Velocity is added
        if not changes:has(Position) then
            changes:set(Position(0, 0))
        end
    end
})

-- Now when you add Velocity, Position is added automatically
local entity = world:spawn(Velocity(10, 20))
-- Entity has both Velocity and Position!
```

### Computed components

Hooks can calculate derived values:

```lua
local Health = tecs.newComponent({
    name = "Health",
    container = HealthType,
    constructor = function(current)
        return {current = current or 100}
    end,
    onAdd = function(self: HealthType, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Automatically set MaxHealth if not present
        if not changes:has(MaxHealth) then
            local health = changes:get(Health)
            changes:set(MaxHealth(health.current))
        end
    end
})
```

### Cleanup with onRemove

```lua
local PhysicsBody = tecs.newComponent({
    name = "PhysicsBody",
    container = PhysicsBodyType,
    onRemove = function(self: PhysicsBodyType, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Clean up related components
        changes:remove(PhysicsVelocity)
        changes:remove(PhysicsCollider)
    end
})
```

### Queries during hooks

When you use `world:query()` inside a hook, the query reflects the **committed state** of the [world](/reference/world),
not pending changes. The component being added/removed is not yet visible to [queries](/reference/queries):

```lua
onAdd = function(self: Component, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
    -- This query won't see the component being added yet
    local query = world:query({include = {ThisComponent}})
    -- query results reflect state before this mutation batch
end
```

### Modifying other entities

Hooks can safely modify other entities using normal world operations:

```lua
onAdd = function(self: Component, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
    -- Update related entities
    world:set(parentEntity, ChildCount(count + 1))

    -- Affect multiple entities
    local enemyQuery = world:query({include = {Enemy}})
    -- Note: Need to extract at least one component for iteration
    for id in enemyQuery(Enemy) do
        world:set(id, Stunned())
    end
end
```

These mutations are added to the same batch and committed together with the original change.

### Changes instance lifetime

The `Changes` object is temporary and only valid during the hook execution. Don't hold onto it outside the callback.

### Self-modification restrictions

Components cannot modify or remove themselves during their own hooks. These restrictions ensure predictable behavior
and prevent confusing edge cases:

**During `onAdd`:**
- Cannot remove the component being added
- Cannot assign the component being added to a different intance

**During `onRemove`:**
- Cannot add the component being removed


## Component storage

Components in Tecs use a storage system to manage their data efficiently. By default, components use the standard
storage implementation which stores component data in tables indexed by entity ID.

**Default storage**

Most components use the default storage which uses a Lua table with fast O(1) lookups by ID, and a size large enough
to contain each component.

**Tag storage**

Tag components automatically use bitset storage for maximum memory efficiency. Since tags have no data,
they only need to track presence/absence, making bitsets ideal.

**FFI storage**

For high-performance scenarios, Tecs provides FFI storage that uses LuaJIT's Foreign Function Interface to store
components as C structs instead of Lua tables.

```lua
tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})
```

See the [FFI Components Guide](/guide/ffi-components) for detailed information on using FFI storage.

**Custom storage**

You can also provide a fully custom storage implementation when creating a component for specialized memory management
beyond what FFI storage provides.

::: warning Advanced feature
Custom storage is an advanced feature. Default, tag, and FFI storage will suffice for most use cases.
:::

```lua
--- Storage interface for managing component data.
interface Storage
    --- Create a new storage table with the given size hint.
    --- @param size Initial size hint (may be ignored).
    --- @return Storage table for component data.
    new: function(self, size: integer): {Component}

    --- Clear all data from the storage table.
    --- @param column The storage table to clear.
    clear: function(self, column: {Component})

    --- Ensure the column has capacity for at least the specified number of components.
    --- @param column The column array to check/resize.
    --- @param needed The minimum capacity required.
    --- @return The column array (may be a new array if reallocation was needed).
    ensureCapacity: function(self, column: {Component}, needed: integer): {Component}


    --- Batch commit components from temporary storage to archetype columns.
    --- @param column The target column in the archetype.
    --- @param startIndex Starting index in the column (1-based).
    --- @param components Array of component instances to commit.
    --- @return The potentially reallocated column.
    commitBatch: function(
        self,
        column: {Component},
        startIndex: integer,
        components: {integer:Component}
    ): {Component}

    --- Called after all changes are committed for this frame.
    --- Allows storage to reset scratch buffers, handle memory management, etc.
    --- @param dt Delta time since last frame in seconds.
    postCommit: function(self, dt: number)

    --- Recycle a component instance back to its storage pool if recycling is enabled.
    --- This is a no-op if recycling is disabled for this storage type.
    --- @param component The component instance to recycle.
    recycle: function(self, component: Component)

    --- Swap two components in the storage column.
    --- @param column The storage column array.
    --- @param indexA First component index (1-based for table storage, 0-based for FFI).
    --- @param indexB Second component index (1-based for table storage, 0-based for FFI).
    swap: function(self, column: {Component}, indexA: integer, indexB: integer)
end
```

The storage table returned by `new()` MUST act like a 1-based Lua table indexed by entity ID integers. It is not
required to allow changing the table, iteration, or responding to `#`.

## Component interface

Components have the following Teal interface definition.

```lua
--- An ECS component.
---
--- ECS components are used to store data that is attached to entities. They can be easily created using
--- `tecs.newComponent`. Components can be attached to entities using `world:set(component, value)` where
--- "component" is the component container and "value" is an instance of the component.
interface Component
    --- The container type of the component, available on instances and containers.
    componentType: self

    --- The name of the component.
    componentName: string

    --- The auto-incrementing ID of the component container.
    componentId: integer

    --- Pre-computed hash contribution for this component.
    componentHash: integer

    --- Indicates that the component is a relationship, and points to the wildcard container of the relationship.
    relationshipContainer: Relationship

    --- Hook called when this component is added to an entity (optional).
    onAdd: OnAdd

    --- Hook called when this component is removed from an entity (optional).
    onRemove: OnRemove

    --- Gets the storage implementation for this component type.
    ---
    --- @return Storage implementation.
    getStorage: function(self): Storage

    --- Creates an instance of the component from the container.
    ---
    --- @param value The component container to create the component instance from.
    --- @param ... Arguments used to create the component.
    --- @return the created component.
    metamethod __call: function(self, ...: any): self
end
```

## ChangeView interface

The `ChangeView` interface is passed to component hooks and provides methods to inspect and modify the entity's
components within the same mutation batch:

```lua
--- A view of pending changes for an entity, used in component hooks.
interface ChangeView
    --- Get a component that exists or will exist after this change.
    get: function<T is Component>(self, component: T): T

    --- Add or update a component in this change batch.
    set: function(self, component: Component)

    --- Remove a component in this change batch.
    remove: function(self, component: Component)

    --- Check if a component exists or will exist.
    has: function(self, component: Component): boolean
end
```