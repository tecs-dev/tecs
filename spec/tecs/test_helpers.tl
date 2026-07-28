local tecs <const> = require("tecs")
local Archetype <const> = require("tecs.internal.Archetype")
local ffi <const> = require("tecs.internal.ffi")

local type DoubleArray = tecs.ecs.DoubleArray
local setDoubleArraySize <const> = ffi.setDoubleArraySize

local record TestHelpers
    -- Export types using record definitions
    record Pos is tecs.ecs.Component
        x: number
        y: number
    end

    record Vel is tecs.ecs.Component
        x: number
        y: number
    end

    record Health is tecs.ecs.Component
        value: number
        max: number
    end

    record Dead is tecs.ecs.Component
    end

    record Sprite is tecs.ecs.Component
        texture: string
        width: number
        height: number
    end

    record Transform is tecs.ecs.Component
        scale: number
        rotation: number
    end

    record ComponentProvider
        PosComponent: Pos
        VelComponent: Vel
        HealthComponent: Health
        DeadComponent: Dead
        SpriteComponent: Sprite
        TransformComponent: Transform

        -- Relationship creators
        createRelationship: function(self: ComponentProvider, name: string, exclusive: boolean): tecs.ecs.Relationship
    end

    -- Create component providers for a test suite
    createComponentProvider: function(prefix: string, testId: integer): ComponentProvider

    -- Count items in a table (useful for testing)
    countTable: function<T>(t: {any: T}): integer

    -- Assert that an archetype contains specific components
    assertArchetypeHasComponents: function(archetype: Archetype, expectedComponents: {tecs.ecs.Component})

    -- Create a simple archetype for testing
    createTestArchetype: function(comps: {tecs.ecs.Component}, id: integer): Archetype

    -- Create an archetype with mocked change observers
    createArchetypeWithMockObservers: function(comps: {tecs.ecs.Component}, id: integer): Archetype

    -- Mock file type for testing
    record MockFile
        write: function(self: MockFile, str: string): MockFile, string
        flush: function(self: MockFile): MockFile, string
        close: function(self: MockFile): MockFile, string
        setvbuf: function(self: MockFile, mode: string, size: integer): MockFile, string
        read: function(self: MockFile, format: string | integer): string
        seek: function(self: MockFile, whence: string, offset: integer): integer, string
    end

    -- Create a mock file for testing file operations
    createMockFile: function(): MockFile

    -- Add entities to an archetype with optional component data
    addEntitiesToArchetype: function(
        archetype: Archetype, entityIds: {integer}, componentData: {{tecs.ecs.Component: any}}
    )
end

function TestHelpers.createComponentProvider(prefix: string, testId: integer): TestHelpers.ComponentProvider
    local provider: TestHelpers.ComponentProvider = {}

    -- Create unique containers for each component to avoid conflicts
    -- Each test gets its own component instances
    local posContainer: TestHelpers.Pos = {}
    local velContainer: TestHelpers.Vel = {}
    local healthContainer: TestHelpers.Health = {}
    local deadContainer: TestHelpers.Dead = {}
    local spriteContainer: TestHelpers.Sprite = {}
    local transformContainer: TestHelpers.Transform = {}

    provider.PosComponent = tecs.ecs.newComponent({
        name = prefix .. "Pos" .. testId,
        container = posContainer,
        fields = {"x", "y"},
        defaults = {0, 0},
    })

    provider.VelComponent = tecs.ecs.newComponent({
        name = prefix .. "Vel" .. testId,
        container = velContainer,
        fields = {"x", "y"},
        defaults = {0, 0},
    })

    provider.HealthComponent = tecs.ecs.newComponent({
        name = prefix .. "Health" .. testId,
        container = healthContainer,
        fields = {"value", "max"},
        defaults = {100, 100},
    })

    provider.DeadComponent = tecs.ecs.newComponent({
        name = prefix .. "Dead" .. testId,
        container = deadContainer,
    })

    provider.SpriteComponent = tecs.ecs.newComponent({
        name = prefix .. "Sprite" .. testId,
        container = spriteContainer,
        fields = {"texture", "width", "height"},
        defaults = {"", 0, 0},
    })

    provider.TransformComponent = tecs.ecs.newComponent({
        name = prefix .. "Transform" .. testId,
        container = transformContainer,
        fields = {"scale", "rotation"},
        defaults = {1, 0},
    })

    function provider:createRelationship(name: string, exclusive: boolean): tecs.ecs.Relationship
        return tecs.ecs.newRelationship({name = prefix .. name .. testId, exclusive = exclusive})
    end

    return provider
end

function TestHelpers.countTable<T>(t: {any: T}): integer
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

function TestHelpers.assertArchetypeHasComponents(archetype: Archetype, expectedComps: {tecs.ecs.Component})
    local luassert <const> = require("luassert")

    for _, comp in ipairs(expectedComps) do
        local found = false
        for archetypeComp, _ in pairs(archetype.columns) do
            if archetypeComp == comp then
                found = true
                break
            end
        end
        luassert.is_true(found, "Archetype should contain component")
    end
end

function TestHelpers.createTestArchetype(comps: {tecs.ecs.Component}, id: integer): Archetype
    return Archetype.new(comps, id or 1)
end

function TestHelpers.createArchetypeWithMockObservers(comps: {tecs.ecs.Component}, id: integer): Archetype
    local spy <const> = require("luassert.spy")
    local archetype = Archetype.new(comps, id or 1)

    -- Note: changeObservers was removed from Archetype since it was unused

    return archetype
end

function TestHelpers.createMockFile(): TestHelpers.MockFile
    local spy <const> = require("luassert.spy")

    return {
        write = spy.new(function() end),
        flush = spy.new(function() end),
        close = spy.new(function() end),
        setvbuf = spy.new(function() end),
        read = spy.new(function(): string return "" end),
        seek = spy.new(function(): integer return 0 end),
    } as any as TestHelpers.MockFile
end

-- Record for accessing archetype implementation fields
local record ArchetypeImpl
    entities: DoubleArray -- FFI array
    columns: {tecs.ecs.Component: any}
end

function TestHelpers.addEntitiesToArchetype(
    archetype: Archetype, entityIds: {integer}, componentData: {{tecs.ecs.Component: any}}
)
    local ffi = require("tecs.internal.ffi")
    local archImpl = archetype as ArchetypeImpl

    for i, entityId in ipairs(entityIds) do
        -- Ensure capacity and add to FFI array
        local newCount = archImpl.entities[0] + 1
        archImpl.entities = ffi.ensureCapacityDouble(archImpl.entities, newCount)
        (archImpl.entities as {integer})[newCount] = entityId
        setDoubleArraySize(archImpl.entities, newCount)

        if componentData and componentData[i] then
            for comp, value in pairs(componentData[i]) do
                local column = archetype.columns[comp]
                if column then
                    column[newCount] = value as any as tecs.ecs.Component
                end
            end
        end
    end
end

return TestHelpers
