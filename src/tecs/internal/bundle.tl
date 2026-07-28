local types <const> = require("tecs.types")

local type Component = types.components.Component
local type World = types.World
local type BundleDef = types.Bundle.Definition

--- Bundle implementation record (implements types.Bundle).
local record Bundle is types.Bundle
    -- Internal: reference to world for spawning
    _world: World
end

--- Bundle module exports.
local record bundle
    --- Create and register a bundle from a declarative definition.
    --- @param world The world to register the bundle with.
    --- @param name The name of the bundle.
    --- @param def The bundle definition (optional).
    --- @return The registered bundle.
    create: function(world: World, name: string, def?: BundleDef): types.Bundle
end

function bundle.create(world: World, name: string, def?: BundleDef): types.Bundle
    assert(world, "Bundle requires a world")
    assert(name and name ~= "", "Bundle requires a name")

    local required = def and def.required or {} as {Component}
    local withEntries = def and def.with or {} as {Component: boolean | function(): Component}
    local requiredCount = #required

    -- Duplicate detection
    local seen: {Component: boolean} = {}
    for i = 1, requiredCount do
        local comp = required[i]
        assert(not seen[comp], "Component already in bundle: " .. comp.componentName)
        seen[comp] = true
    end

    -- Lay out typeArray with required slots first, then with-default slots.
    -- factoryArray is parallel but only populated for with-default slots.
    local typeArray: {Component} = {}
    local factoryArray: {function(): Component} = {}
    local requiredNames: {string} = {}
    local defaultedNames: {string} = {}

    for i = 1, requiredCount do
        local t = required[i]
        typeArray[i] = t
        requiredNames[i] = t.componentName
    end
    local withIndex = 0
    for t, value in pairs(withEntries) do
        assert(not seen[t], "Component already in bundle: " .. t.componentName)
        seen[t] = true
        withIndex = withIndex + 1
        typeArray[requiredCount + withIndex] = t
        local factory: function(): Component
        if value is function(): Component then
            factory = value
        elseif value == true then
            factory = function(): Component return t() end
        else
            error("Bundle 'with' value for " .. t.componentName .. " must be a factory function or `true`")
        end
        factoryArray[requiredCount + withIndex] = factory
        defaultedNames[withIndex] = t.componentName
    end

    -- Ask the world to codegen a specialized spawn function for this
    -- bundle's ordered component list. The generated function writes
    -- directly to the target archetype, bypassing the deferred staging
    -- path. Bundle spawn bookkeeping lives on the world.
    local worldAny = world as {string: any}
    local codegen = worldAny._codegenBundleSpawn as function(
        any, {Component}, {function(): Component}, integer
    ): function(any, ...: Component): integer
    local spawnFn = codegen(world, typeArray, factoryArray, requiredCount)

    -- Assemble the bundle object. `spawn` is assigned as a per-instance
    -- field (not a method on the Bundle record) so that `bundle:spawn()`
    -- dispatches directly to the codegen'd closure with zero wrapper frames.
    local bundleObj: Bundle = {
        name = name,
        required = requiredNames,
        defaulted = defaultedNames,
        _world = world,
    }
    (bundleObj as {string: any}).spawn = spawnFn
    setmetatable(bundleObj as table, {__index = Bundle})

    -- Register with world
    local bundles = worldAny._bundles as {string: Bundle}
    if not bundles then
        bundles = {}
        worldAny._bundles = bundles
    end
    assert(not bundles[name], "Bundle with name '" .. name .. "' already exists")
    bundles[name] = bundleObj

    return bundleObj
end

return bundle
