--[[
Tecs, a typed entity component system for Lua, typed with Teal.
]]

-- Basic Lua compatibility layer
if not table.unpack then
    -- Ensure table has an unpack function.
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

local types <const> = require("tecs.types")
local Context <const> = require("tecs.internal.Context")

-- Internal modules
local builtins <const> = require("tecs.internal.builtins")
local bundle <const> = require("tecs.internal.bundle")
local compat <const> = require("tecs.internal.utils.compat")
local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local ffi <const> = require("tecs.internal.ffi")
local logging <const> = require("tecs.internal.utils.logging")
local phases <const> = require("tecs.internal.phases")
local pool <const> = require("tecs.internal.utils.pool")
local state <const> = require("tecs.internal.state")
local WorldImpl <const> = require("tecs.internal.world")

--- The main entry point of Tecs.
local record tecs

    type World = types.World
    type System = types.System
    type Plugin = types.Plugin
    type Pipeline = types.Pipeline
    type Component = types.Component
    type ComponentOptions<C> = components.ComponentOptions<C>
    type FFIComponentOptions<C> = components.FFIComponentOptions<C>
    type Relationship = types.Relationship
    type Query = types.Query
    type Archetype = types.Archetype
    type Event = events.Event
    type Emitter = events.Emitter
    type EventListener = events.EventListener
    type EventConstructor = events.EventConstructor
    type Storage = types.Storage
    type Key<T> = Context.Key<T>
    type States<V> = state.States<V>
    type DefaultedStates<V> = state.DefaultedStates<V>
    type StateContainer = state.StateContainer
    type Stats = types.Stats
    type ChangeView = types.ChangeView
    type Phase = types.Phase
    type SystemConfig = types.SystemConfig
    type Int32Array = types.Int32Array
    type Float32Array = types.Float32Array
    type BundleBuilder = bundle.Builder
    type Bundle = bundle.Bundle

    Context: Context

    compat: compat
    ffi: ffi
    logging: logging
    phases: phases
    pool: pool
    builtins: builtins

    --- Create a new World.
    ---
    --- @param timestep The fixed timestep of the game (the target FPS of the game).
    --- @return the created World.
    newWorld: function(config?: types.WorldConfig): World

    --- Creates and registers a new type of component.
    ---
    --- The component is registered globally with all created worlds and does not need to be manually registered.
    ---
    --- @param options Component configuration including name, container, and optional constructor/storage.
    --- @return the configured component.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Create a tag component that uses bitset storage for efficiency.
    ---
    --- Tags are components with no data. Their presence alone carries meaning.
    ---
    --- @param options Tag component options.
    --- @return The created tag component.
    newTagComponent: function(options: components.TagComponentOptions): Component

    --- Creates and registers a relationship component that links entities together.
    ---
    --- Relationships allow entities to reference other entities with optional data.
    --- They support automatic cleanup and referential integrity.
    ---
    --- @param config Relationship configuration including name, exclusivity, and optional data.
    --- @return The configured relationship component.
    newRelationship: function<R is Relationship>(config: components.RelationshipOptions<R>): R

    --- Create a tag relationship with efficient FFI storage.
    ---
    --- @param config Tag relationship configuration including name and options.
    --- @return The created tag relationship component.
    newTagRelationship: function(config: components.TagRelationshipOptions): Relationship

    --- Create an FFI relationship with data fields for high performance.
    ---
    --- @param config FFI relationship configuration including fields and container.
    --- @return The created FFI relationship component.
    newFFIRelationship: function<R is Relationship>(config: components.FFIRelationshipOptions<R>): R

    --- Creates and registers an FFI-based component for efficient storage and performance.
    ---
    --- FFI components leverage LuaJIT's ability to define FFI structs at runtime, and they store structs in
    --- FFI arrays with manual memory management.
    ---
    --- @param options Configuration including name, container, fields, and optional recycling.
    --- @return The created FFI component.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Create a new bundle builder for creating bundles, or prefabs.
    ---
    --- @return The created bundle builder.
    newBundle: function(): BundleBuilder

    --- Create a new typed configuration key for storing resources in a Context.
    ---
    --- @param forType Optional type parameter for type inference.
    --- @return A new key that can be used to store values of type T.
    newKey: function<T>(forType?: T): Key<T>

    --- Create a new state container for managing states independently of the world.
    ---
    --- Most users should use the world's built-in state management (world:setState, etc.)
    --- instead of creating separate state containers. This is for advanced use cases.
    ---
    --- @return A new state container.
    newStateContainer: function(): state.StateContainer

    --- Create a new event emitter for managing events.
    ---
    --- @return A new event emitter.
    newEmitter: function(): Emitter

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- The initializer is used to configure the state of event instances.
    ---
    --- @param event The event instance to configure.
    --- @param constructor A function that creates an instance of the event.
    newEvent: function<E is Event>(event: E, constructor: EventConstructor<E>)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- The initializer is used to configure the state of event instances.
    ---
    --- @param event The event type to configure.
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- Safely enable LuaJIT compilation if available.
    ---
    --- This function attempts to enable JIT compilation without breaking type safety.
    --- It's safe to call even when JIT is not available.
    ---
    --- @return true if JIT was successfully enabled, false otherwise.
    enableJit: function(): boolean
end

--- Safely enable LuaJIT compilation if available.
local function enableJit(): boolean
    local trickTealWithVariable = "jit"
    local success, result = pcall(require, trickTealWithVariable)

    if not success or not result then
        return false
    end

    local jitTable = result as {string:function}
    if type(jitTable.on) == "function" then
        jitTable.on()
        return true
    end

    return false
end

tecs.newComponent = components.newComponent
tecs.newTagComponent = components.newTagComponent
tecs.newFFIComponent = components.newFFIComponent
tecs.newRelationship = components.newRelationship
tecs.newTagRelationship = components.newTagRelationship
tecs.newFFIRelationship = components.newFFIRelationship
tecs.newWorld = WorldImpl.new
tecs.newKey = Context.newKey
tecs.newBundle = bundle.newBuilder
tecs.newStateContainer = state.newStateContainer
tecs.newEmitter = events.newEmitter
tecs.newEvent = events.newEvent
tecs.newFFIEvent = events.newFFIEvent
tecs.enableJit = enableJit

tecs.Context = Context
tecs.compat = compat
tecs.ffi = ffi
tecs.phases = phases
tecs.pool = pool
tecs.builtins = builtins
tecs.logging = logging

return tecs
