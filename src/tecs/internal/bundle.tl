local types <const> = require("tecs.types")
local pool <const> = require("tecs.internal.utils.pool")

local acquireArray <const> = pool.acquireArray
local releaseArray <const> = pool.releaseArray
local unpack <const> = table.unpack

local type Component = types.Component

--- Bundle builder for creating type-safe component bundles.
local record bundle
    --- A bundle is a function that creates components with optional overrides.
    type Bundle = function(...: Component): Component...

    --- Internal builder state.
    record Builder
        --- Add a component factory to the bundle.
        --- @param componentType The component type to add.
        --- @param factory Function that creates an instance of the component.
        --- @return The builder for chaining.
        add: function<T is Component>(self: Builder, componentType: T, factory: function(): T): Builder

        --- Require a component to be provided in overrides.
        --- @param componentType The component type that must be provided.
        --- @return The builder for chaining.
        require: function<T is Component>(self: Builder, componentType: T): Builder

        --- Build the final bundle function.
        --- @return A function that creates components with optional overrides.
        build: function(self: Builder): Bundle

        _factories: {Component:function(): Component}
    end

    --- Create a new bundle builder.
    --- @return A new builder for creating bundles.
    newBuilder: function(): Builder

    --- Create a new bundle builder.
    --- @return A new builder for creating bundles.
    metamethod __call: function(self: bundle): Builder
end

local Builder <const> = bundle.Builder

function Builder:add<T is Component>(componentType: T, factory: function(): T): Builder
    self._factories[componentType as Component] = factory as function(): Component
    return self
end

function Builder:require<T is Component>(componentType: T): Builder
    return self:add(componentType, function(): Component
        error("Required component missing: " .. componentType.componentName)
    end)
end

function Builder:build(): bundle.Bundle
    -- Convert factory map to static arrays for faster runtime execution via array indexing.
    local typeArray: {Component} = {}
    local factoryArray: {function(): Component} = {}
    local typeIndex: {Component: integer} = {}

    -- Linearize the factory hash map into parallel arrays.
    -- * typeArray[k] and factoryArray[k] correspond to each other
    -- * typeIndex maps component type -> array index for O(1) lookup
    local count = 0
    local componentType, factory = next(self._factories)
    while componentType do
        count = count + 1
        typeArray[count] = componentType
        factoryArray[count] = factory
        typeIndex[componentType] = count
        componentType, factory = next(self._factories, componentType)
    end
    local bundleSize = count

    return function(...: Component): Component...
        local n = select('#', ...)
        local result: {Component} = {}
        local setIndices: {any} = acquireArray(bundleSize)

        -- Add given component values to the result.
        for j = 1, n do
            local c = select(j, ...) as Component
            local index = typeIndex[c.componentType as Component]
            result[#result + 1] = c
            if index ~= nil then
                setIndices[index] = c -- Bundle component: track override
            end
        end

        -- Add default values to the result.
        for k = 1, bundleSize do
            local c = setIndices[k]
            if not c then
                result[#result + 1] = factoryArray[k]()
            end
        end

        releaseArray(setIndices)
        return unpack(result)
    end
end

local BUILDER_META <const>: metatable<Builder> = {
    __index = Builder
}

function bundle.newBuilder(): Builder
    return setmetatable({_factories = {}}, BUILDER_META)
end

return bundle