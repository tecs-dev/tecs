local tecsTypes <const> = require("tecs.types")

local type Archetype = tecsTypes.Archetype
local type ArchetypeChangeObserver = tecsTypes.ArchetypeChangeObserver
local type Component = tecsTypes.Component

local record types

    --- ECS database container (the guts of Tecs).
    interface DB
        --- Tick update the DB to do any periodic cleanup tasks.
        --- @param dt The delta time since the last tick.
        tick: function(self, dt: number)

        --- Spawn and initialize a new entity with the given components.
        ---
        --- @param ... Variable number of components to add to the entity.
        --- @return the ID of the spawned, or soon to be spawned, entity.
        spawn: function(self, ...: Component): integer

        --- Despawns an entity and removes it from the ECS container.
        ---
        --- @param id The entity ID to despawn.
        despawn: function(self, id: integer)

        --- Checks if an entity has a component.
        ---
        --- @param id The entity ID to check.
        --- @param component The component to check.
        --- @return True if the entity has the component.
        hasComponent: function(self, id: integer, component: Component): boolean

        --- Gets a component from an entity.
        ---
        --- @param id The entity ID to get the component from.
        --- @param component The component to get.
        --- @return The component, or nil.
        getComponent: function<C is Component>(self, id: integer, component: C): C

        --- Add a component to an entity.
        --- @param id The entity ID to add the component to.
        --- @param component The component to add.
        addComponent: function(self, integer: integer, Component: Component)

        --- Remove a component from an entity.
        --- @param id The entity ID to remove the component from.
        removeComponent: function(self, integer: integer, Component: Component)

        --- Gets or creates an archetype with the given components.
        ---
        --- @param components The components to find the archetype for.
        --- @return The archetype with the given components, or nil.
        getArchetype: function(self, components: {Component}): Archetype

        --- Finds all archetypes that match the given include and exclude components.
        ---
        --- @param include The components that must be included in the archetype.
        --- @param exclude The components that must not be included in the archetype.
        --- @return The archetypes that match.
        findArchetypes: function(self, include: {Component}, exclude: {Component}): {Archetype}

        --- Add an archetype change observer to the DB.
        ---
        --- @param observer The archetype change observer to add.
        addChangeObserver: function(self, observer: ArchetypeChangeObserver)

        --- Commits any pending changes to the DB.
        commit: function(self, transaction?: Transaction)

        --- Commits the current transaction (called after each system).
        commitTransaction: function(self)

        --- Set the world instance for hooks.
        --- @param world The world instance.
        setWorld: function(self, world: tecsTypes.World)

        --- Set whether the DB is frozen (during system execution).
        --- @param frozen Whether the DB is frozen.
        setFrozen: function(self, frozen: boolean)
    end

    interface Transaction
        db: DB
    end
end

return types