local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local state <const> = require("tecs.internal.state")
local types <const> = require("tecs.types")

local type Component = types.Component
local type Relationship = types.Relationship

--- Builtin components, relationships, and events for Tecs.
local record builtins

    --- Provides a name for an entity.
    record Name is Component
        value: string

        --- Creates a new Name component.
        ---
        --- @param value The name of the entity.
        --- @return the created name component.
        metamethod __call: function(self, value: Name | string): Name
    end

    --- Gives an entity an event dispatcher for handling events.
    ---
    --- Note that this component _is_ an Emitter.
    record Emitter is Component, events.Emitter
        --- Create a new dispatcher.
        ---
        --- @param consumer Function that gets the dispatcher and can add event observers.
        --- @return the created dispatcher component.
        metamethod __call: function(self, consumer?: function(d: events.Emitter)): Emitter
    end

    --- Provides the coordinates and transform of an entity.
    record Transform is Component
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
        --- @param xOrValue The x position or full transform data if passing an array.
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

    --- Despawns an entity when the TTL reaches zero.
    record TTL is Component
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

    --- An event emitted when a specific entity is spawned.
    record OnSpawn is events.Event
        entity: integer

        --- Create a new OnSpawn event.
        metamethod __call: function(self, entity: integer): OnSpawn
    end

    --- An event emitted when a specific entity is despawned.
    record OnDespawn is events.Event
        entity: integer

        --- Create a new OnDespawn event.
        metamethod __call: function(self, entity: integer): OnDespawn
    end

    --- The built-in debug state machine.
    record Debug is state.DefaultedStates<Values>
        enum Values
            "off"
            "on"
        end
        default: Values
    end

    --- A built-in child relationship.
    ChildOf: Relationship
end

builtins.Debug.default = "off"

-------------------------------------------------------------------------------
--- Setup relationships
-------------------------------------------------------------------------------

builtins.ChildOf = components.newTagRelationship({
    name = "ChildOf",
    exclusive = true,
    onRemove = function(self: types.Relationship, w: types.World, entityId: integer, _changes: types.ChangeView)
        -- Check if the parent entity is no longer alive (being despawned)
        local relationship = self
        if not w:isAlive(relationship.target) then
            -- Parent was despawned, so despawn this child too
            w:despawn(entityId)
        end
        -- Otherwise, this is a regular removal (orphaning or reparenting), so allow it
    end
})

-------------------------------------------------------------------------------
--- Setup events
-------------------------------------------------------------------------------

events.newFFIEvent(builtins.OnSpawn, {
    {"entity", "int32_t"}
}, "Tecs_OnSpawn")

events.newFFIEvent(builtins.OnDespawn, {
    {"entity", "int32_t"}
}, "Tecs_OnDespawn")

-------------------------------------------------------------------------------
--- Setup components
-------------------------------------------------------------------------------

components.newComponent({
    name = "Name",
    container = builtins.Name,
    constructor = function(value: builtins.Name | string): builtins.Name
        assert(value, "Missing name")
        if value is string then
            return {value = value}
        elseif type(value) == "table" then
            assert((value as table).value, "Name component must be a string or a table of {value = string}")
            return value as builtins.Name
        else
            error("Invalid name: " .. tostring(value))
        end
    end
})

components.newComponent({
    name = "Emitter",
    container = builtins.Emitter,
    constructor = function(consumer?: function(events.Emitter)): builtins.Emitter
        local e = events.newEmitter()
        if consumer then
            consumer(e)
        end
        return e as builtins.Emitter
    end
})

components.newFFIComponent({
    name = "Transform",
    container = builtins.Transform,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"z", "float"},
        {"layer", "int32_t"}
    },
    recycle = true,
    initializer = function(
        constructor: function(any...): builtins.Transform,
        x: number,
        y: number,
        z: number,
        layer: integer
    ): builtins.Transform
        -- Handle different argument patterns
        if type(x) == "table" then
            -- Single table argument case
            local transform = x as builtins.Transform
            x, y, z, layer = transform.x, transform.y, transform.z, transform.layer
        end
        if layer == nil then
            layer = 1
        elseif layer < 1 then
            error("Transform layer must be greater than 0, got: " .. tostring(layer))
        end
        return constructor(x or 0, y or 0, z or 0, layer)
    end
})

local function percentComplete(self: builtins.TTL): number
    return 1 - (self.remaining / self.startingTime)
end

components.newComponent({
    name = "TTL",
    container = builtins.TTL,
    constructor = function(remaining: number): builtins.TTL
        assert(remaining > 0, "TTL must be greater than 0")
        return {
            remaining = remaining,
            startingTime = remaining,
            percentComplete = percentComplete
        }
    end
})

return builtins
