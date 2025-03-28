--[[
    world.tl - World implementation and system orchestration

    This module implements the World class, which serves as the primary interface for
    users of the ECS framework. It provides high-level operations for managing entities,
    components, systems, and game state while coordinating all the internal subsystems.

    WARNING: This is an internal module and should not be required directly.
    Instead, import the `tecs` module and use the methods provided there.
]]

local Context <const> = require("tecs.internal.Context")
local types <const> = require("tecs.types")
local state <const> = require("tecs.internal.state")
local db <const> = require("tecs.internal.db")
local pipeline <const> = require("tecs.internal.pipeline")
local builtins <const> = require("tecs.internal.builtins")
local builtinPlugin <const> = require("tecs.internal.builtins.plugin")
local queries <const> = require("tecs.internal.queries")
local phases <const> = require("tecs.internal.phases")
local events <const> = require("tecs.internal.events")
local compat <const> = require("tecs.internal.utils.compat")
local table_clear <const> = compat.clear

local type World = types.World
local type System = types.System
local type Component = types.Component
local type Query = types.Query
local type ArchetypeChangeObserver = types.ArchetypeChangeObserver
local type Archetype = types.Archetype
local type QueryDescriptor = types.QueryDescriptor
local type Int32Array = types.Int32Array
local type States = state.States
local type StateContainer = state.StateContainer
local type Event = events.Event
local type Pipeline = types.Pipeline
local type Phase = types.Phase
local type Plugin = types.Plugin

local record WorldImpl is types.World
    pipeline: Pipeline
    resources: Context
    stateContainer: StateContainer
    eventEmitter: events.Emitter
    db: db.DB
    savedQueries: {Query}
    commands: {types.Command}
    -- Lazy emitter storage: maps entity IDs to emitters that haven't been committed as components yet
    lazyEmitters: {integer: events.Emitter}
end

local WORLD_MT <const>: metatable<World> = { __index = WorldImpl }

function WorldImpl.new(config?: types.WorldConfig): World
    config = config or {}
    local emitter = events.newEmitter()
    local database = db.DB.new()
    local instance: WorldImpl = {
        resources = Context.new(),
        stateContainer = state.newStateContainer(),
        eventEmitter = emitter,
        db = database,
        commands = {},
        savedQueries = {},
        lazyEmitters = {}
    }

    config.pipelineFactory = config.pipelineFactory or pipeline.new
    -- Commit transaction after each system completes
    local runAfter = function(world: World)
        -- Cast to implementation type to access db
        local impl = world as WorldImpl
        impl.db:setFrozen(false)
        impl.db:commitTransaction()
        impl.db:setFrozen(true)
    end
    instance.pipeline = config.pipelineFactory(config.timestep, runAfter)

    setmetatable(instance as World, WORLD_MT)

    -- Set world reference for component hooks
    database:setWorld(instance as World)

    -- Database is self-contained with Transaction system

    builtinPlugin(instance)
    return instance
end

function WorldImpl:addPlugin(plugin: Plugin)
    plugin(self)
end

-------------------------------------------------------------------------------
-- Component handling
-------------------------------------------------------------------------------

function WorldImpl:get<T is Component>(entity: integer, component: T): T
    local result = self.db:getComponent(entity, component)

    -- If requesting an Emitter and we don't have one committed, check lazy storage
    if not result and component == builtins.Emitter then
        local lazyEmitter = self.lazyEmitters[entity]
        if lazyEmitter then
            return lazyEmitter as T
        end
    end

    return result
end

function WorldImpl:set(entity: integer, component: Component)
    -- If setting an Emitter component, clear any lazy emitter
    if (component.componentType as Component) == builtins.Emitter then
        self.lazyEmitters[entity] = nil
    end
    self.db:addComponent(entity, component)
end

function WorldImpl:remove(entity: integer, component: Component)
    self.db:removeComponent(entity, component)
    -- Note: We don't clear lazy emitters on remove, since getEntityEmitter
    -- might be called again and we want to maintain the same emitter instance
end

function WorldImpl:command(command: types.Command)
    -- If the DB is not frozen, execute immediately
    if not self.db.frozen then
        command()
    else
        -- Otherwise defer the command
        self.commands[#self.commands + 1] = command
    end
end

-------------------------------------------------------------------------------
-- Entity handling
-------------------------------------------------------------------------------

function WorldImpl:spawn(...: Component): integer
    return self.db:spawn(...)
end

function WorldImpl:despawn(entity: integer)
    -- Clean up any lazy emitter for this entity
    self.lazyEmitters[entity] = nil
    self.db:despawn(entity)
end

function WorldImpl:isAlive(entity: integer): boolean
    -- Check if entity is currently being despawned
    if self.db.transaction:isBeingDespawned(entity) then
        return false
    end

    -- Check if entity exists in the database
    -- An entity is alive if it has been spawned and not despawned
    local archetypeId = self.db.entityIndex:get(entity)
    if archetypeId then
        -- Also check if it's marked for despawn but not processed yet
        return not self.db.transaction.despawns[entity]
    end

    -- Also check if entity is staged in transaction
    return self.db.transaction:isSpawn(entity) and not self.db.transaction.despawns[entity]
end

-------------------------------------------------------------------------------
-- State machine handling
-------------------------------------------------------------------------------

function WorldImpl:getState<V, S is States<V>>(s: S): V
    return self.stateContainer:getState(s)
end

function WorldImpl:inState<V, S is States<V>>(s: S, value: V): boolean
    return self.stateContainer:inState(s, value)
end

function WorldImpl:setState<V, S is States<V>>(s: S, value: V)
    self.stateContainer:setState(s, value)
end

function WorldImpl:onExitState<V, S is States<V>>(s: S, value: V, callback: function())
    self.stateContainer:onExitState(s, value, callback)
end

function WorldImpl:onTransitionState<V, S is States<V>>(s: S, from: V, to: V, callback: function())
    self.stateContainer:onTransitionState(s, from, to, callback)
end

function WorldImpl:onEnterState<V, S is States<V>>(s: S, value: V, callback: function())
    self.stateContainer:onEnterState(s, value, callback)
end

-------------------------------------------------------------------------------
-- System handling
-------------------------------------------------------------------------------

function WorldImpl:addSystem(config: types.SystemConfig)
    self.pipeline:addSystem(assert(config, "Missing system config"))
end

function WorldImpl:removeSystem(phase: Phase, system: System | string)
    self.pipeline:removeSystem(phase, system)
end

-------------------------------------------------------------------------------
-- Query handling
-------------------------------------------------------------------------------

function WorldImpl:query(descriptor: QueryDescriptor): Query
    local matchingArchetypes = self.db:findArchetypes(descriptor.include, descriptor.exclude)
    local query = queries.new(descriptor, matchingArchetypes)
    self.db:addChangeObserver(query as ArchetypeChangeObserver)
    if descriptor.save then
        self.savedQueries[#self.savedQueries + 1] = query
    end
    return query
end

local NO_ENTITY_FUNCTION <const> = function(): Archetype, integer, Int32Array
    return nil, 0, nil
end

function WorldImpl:findArchetypes(component: Component): function(): (Archetype, integer, Int32Array)
    local archetypes = self.db.archetypeIndex:getArchetypesWithComponent(component)
    if archetypes then
        local key = next(archetypes)
        if key then
            return function(): (Archetype, integer, Int32Array)
                local archetype = key
                if archetype then
                    key = next(archetypes, key)
                    local entities = archetype.entities
                    return archetype, entities[0], entities
                end
                return nil, 0, nil
            end
        end
    end
    return NO_ENTITY_FUNCTION
end

-------------------------------------------------------------------------------
-- Update handling
-------------------------------------------------------------------------------

function WorldImpl:update(dt: number)
    -- If there's an open frame from initialization, end it first
    if self.db.inFrame then
        self.db:endFrame()
    end

    -- Start the frame in the DB
    self.db:beginFrame(dt)
    -- Freeze the DB during system execution
    self.db:setFrozen(true)
    -- Run all systems in the pipeline
    self.pipeline:update(dt, self)
    -- Unfreeze the DB after systems complete
    self.db:setFrozen(false)
    -- End the frame and commit any changes
    self.db:endFrame()
    -- Execute deferred commands
    for i = 1, #self.commands do
        self.commands[i]()
    end
    table_clear(self.commands)
end

-------------------------------------------------------------------------------
-- Event handling
-------------------------------------------------------------------------------

function WorldImpl:observe<E is Event>(eventType: E, observer: function(E), id?: string)
    self.eventEmitter:observe(eventType, observer, id)
end

function WorldImpl:observeOnce<E is Event>(eventType: E, observer: function(E))
    self.eventEmitter:observeOnce(eventType, observer)
end

function WorldImpl:stopObserving<E is Event>(eventType: E, observer: function(E) | string)
    self.eventEmitter:stopObserving(eventType, observer)
end

function WorldImpl:hasObservers<E is Event>(eventType: E): boolean
    return self.eventEmitter:hasObservers(eventType)
end

function WorldImpl:emit<E is Event>(event: E)
    self.eventEmitter:emit(event)
end

function WorldImpl:getEntityEmitter(entity: integer): events.Emitter
    -- First check committed data
    local e = self:get(entity, builtins.Emitter)
    if e then
        return e
    end

    -- Check if an emitter is pending in the transaction
    local pending = self.db.transaction:getPendingComponent(entity, builtins.Emitter)
    if pending then
        return pending
    end

    -- Check if we have a lazy emitter stored for this entity
    local lazyEmitter = self.lazyEmitters[entity]
    if lazyEmitter then
        return lazyEmitter
    end

    -- Finally, create a new lazy emitter (don't add it as a component yet)
    local newEmitter = builtins.Emitter()
    self.lazyEmitters[entity] = newEmitter
    return newEmitter
end

-------------------------------------------------------------------------------
-- Phase handling
-------------------------------------------------------------------------------

function WorldImpl:enablePhase(phase: Phase)
    self.pipeline:enablePhase(phase)
end

function WorldImpl:disablePhase(phase: Phase)
    self.pipeline:disablePhase(phase)
end

function WorldImpl:startup()
    self.pipeline:run(phases.StartupGroup, 0, self)
end

function WorldImpl:shutdown()
    self.pipeline:run(phases.ShutdownGroup, 0, self)
end

function WorldImpl:getStats(fill?: types.Stats): types.Stats
    fill = fill or {}

    -- Get stats from DB
    local entityCount, archetypeCount, componentCount = self.db:getStats()

    fill.entities = entityCount
    fill.archetypes = archetypeCount
    fill.components = componentCount
    fill.systems = self.pipeline.count
    return fill
end

return WorldImpl
