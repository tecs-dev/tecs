--- Internal fixed-iteration mutation tracking.
---
--- Consumers opt specific component columns into tracking. Disabled worlds
--- pay one raw table lookup from mutable archetype access; enabled worlds
--- record a monotonically increasing mutation version and the fixed
--- iteration in which a tracked column was touched.

local types <const> = require("tecs.types")

local type World = types.World
local type Component = types.components.Component
local type Archetype = types.Archetype

local record State
    tracked: {Component: boolean}
    trackedList: {Component}
    versions: {Archetype: {Component: integer}}
    fixedWrites: {Archetype: {Component: integer}}
    structureVersions: {Archetype: integer}
    beforeCallbacks: {function(World)}
    callbacks: {function(World)}
    step: integer
    active: boolean
end

local record fixedtracking
    track: function(world: World, component: Component)
    enabled: function(dirtySet: table): boolean
    beforeStep: function(world: World, callback: function(World))
    afterStep: function(world: World, callback: function(World))
    beginStep: function(world: World)
    finishStep: function(world: World)
    mark: function(archetype: Archetype, component: Component)
    markAll: function(archetype: Archetype)
    version: function(archetype: Archetype, component: Component): integer
    structureVersion: function(archetype: Archetype): integer
    wroteThisStep: function(world: World, archetype: Archetype, component: Component): boolean
    currentStep: function(world: World): integer
end

local statesByWorld <const>: {World: State} = setmetatable({}, {__mode = "k"} as metatable<{World: State}>)
local statesByDirtySet <const>: {table: State} = setmetatable({}, {__mode = "k"} as metatable<{table: State}>)

local function dirtySetOf(world: World): table
    return ((world as {string: any})._dirtyArchetypes as table)
end

local function stateFor(world: World): State
    local state = statesByWorld[world]
    if state then
        return state
    end

    state = {
        tracked = {},
        trackedList = {},
        versions = setmetatable({}, {__mode = "k"}) as {Archetype: {Component: integer}},
        fixedWrites = setmetatable({}, {__mode = "k"}) as {Archetype: {Component: integer}},
        structureVersions = setmetatable({}, {__mode = "k"}) as {Archetype: integer},
        beforeCallbacks = {},
        callbacks = {},
        step = 0,
        active = false,
    }
    statesByWorld[world] = state
    statesByDirtySet[dirtySetOf(world)] = state
    return state
end

function fixedtracking.track(world: World, component: Component)
    local state = stateFor(world)
    if state.tracked[component] then
        return
    end
    state.tracked[component] = true
    state.trackedList[#state.trackedList + 1] = component
    world:forEachArchetype(function(archetype: Archetype) (archetype as {string: any})._fixedTracking = true end)
end

function fixedtracking.enabled(dirtySet: table): boolean
    return statesByDirtySet[dirtySet] ~= nil
end

function fixedtracking.beforeStep(world: World, callback: function(World))
    local state = stateFor(world)
    state.beforeCallbacks[#state.beforeCallbacks + 1] = callback
end

function fixedtracking.afterStep(world: World, callback: function(World))
    local state = stateFor(world)
    state.callbacks[#state.callbacks + 1] = callback
end

function fixedtracking.beginStep(world: World)
    local state = statesByWorld[world]
    if not state then
        return
    end
    state.step = state.step + 1
    local callbacks = state.beforeCallbacks
    for i = 1, #callbacks do
        callbacks[i](world)
    end
    state.active = true
end

function fixedtracking.finishStep(world: World)
    local state = statesByWorld[world]
    if not state then
        return
    end
    local callbacks = state.callbacks
    for i = 1, #callbacks do
        callbacks[i](world)
    end
    state.active = false
end

function fixedtracking.mark(archetype: Archetype, component: Component)
    local dirtySet = (archetype as {string: any})._dirtySet as table
    local state = statesByDirtySet[dirtySet]
    if not state or not state.tracked[component] then
        return
    end

    local versions = state.versions[archetype]
    if not versions then
        versions = {}
        state.versions[archetype] = versions
    end
    versions[component] = (versions[component] or 0) + 1

    local writes = state.fixedWrites[archetype]
    if state.active then
        if not writes then
            writes = {}
            state.fixedWrites[archetype] = writes
        end
        writes[component] = state.step
    elseif writes then
        -- A later variable-rate mutation supersedes the fixed sample.
        -- Consumers must snap to that value instead of interpolating it.
        writes[component] = -1
    end
end

function fixedtracking.markAll(archetype: Archetype)
    local dirtySet = (archetype as {string: any})._dirtySet as table
    local state = statesByDirtySet[dirtySet]
    if not state then
        return
    end

    local columns = (archetype as {string: any}).columns as table
    local tracked = state.trackedList
    local touched = false
    for i = 1, #tracked do
        local component = tracked[i]
        if rawget(columns, component) ~= nil then
            touched = true
            fixedtracking.mark(archetype, component)
        end
    end
    if touched then
        state.structureVersions[archetype] = (state.structureVersions[archetype] or 0) + 1
    end
end

function fixedtracking.version(archetype: Archetype, component: Component): integer
    local dirtySet = (archetype as {string: any})._dirtySet as table
    local state = statesByDirtySet[dirtySet]
    if not state or not state.tracked[component] then
        return -1
    end
    local versions = state.versions[archetype]
    return versions and (versions[component] or 0) or 0
end

function fixedtracking.structureVersion(archetype: Archetype): integer
    local dirtySet = (archetype as {string: any})._dirtySet as table
    local state = statesByDirtySet[dirtySet]
    return state and (state.structureVersions[archetype] or 0) or -1
end

function fixedtracking.wroteThisStep(world: World, archetype: Archetype, component: Component): boolean
    local state = statesByWorld[world]
    if not state then
        return false
    end
    local writes = state.fixedWrites[archetype]
    return writes ~= nil and writes[component] == state.step
end

function fixedtracking.currentStep(world: World): integer
    local state = statesByWorld[world]
    return state and state.step or 0
end

return fixedtracking
