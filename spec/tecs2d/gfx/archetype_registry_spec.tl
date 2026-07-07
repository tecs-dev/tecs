-- archetype_registry: renderer-owned per-archetype state. Validates that
-- the registry walks existing archetypes, subscribes to ArchetypeCreated
-- for future ones, attaches the state as an entity observer, and cleans
-- up on archetype destruction.

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")

local Pos = tecs.newComponent({
    name = "RegistrySpecPos",
    container = {},
    fields = {"x", "y"},
})
local Vel = tecs.newComponent({
    name = "RegistrySpecVel",
    container = {},
    fields = {"dx", "dy"},
})
local Tag = tecs.newTagComponent({name = "RegistrySpecTag"})

local function makeState(arch: tecs.Archetype): {string:any}
    return {
        archetype = arch,
        events = {} as {{string:any}},
        onEntitiesAdded = function(self: any, _arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
            local events = (self as {string:any}).events as {{string:any}}
            events[#events + 1] = {kind = "added", first = firstRow, last = lastRow, count = count}
        end,
        onEntitiesRemoved = function(self: any, _arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
            local events = (self as {string:any}).events as {{string:any}}
            events[#events + 1] = {kind = "removed", first = firstRow, last = lastRow, count = count}
        end,
        onArchetypeDestroyed = function(self: any, _arch: tecs.Archetype)
            local events = (self as {string:any}).events as {{string:any}}
            events[#events + 1] = {kind = "destroyed"}
        end,
        flush = function(self: any)
            local events = (self as {string:any}).events as {{string:any}}
            events[#events + 1] = {kind = "flushed"}
        end,
    }
end

describe("archetype_registry", function()
    it("registers archetypes that match the predicate", function()
        local world = tecs.newWorld()
        world:spawn(Pos(1, 2))
        world:spawn(Pos(3, 4), Tag)
        world:spawn(Vel(1, 1))  -- doesn't match (no Pos)

        local registry = archetype_registry.new(world, {
            name = "test",
            matches = function(arch: tecs.Archetype): boolean
                return arch:get(Pos) ~= nil
            end,
            create = makeState,
        })

        local count = 0
        for _, _state in registry:archetypes() do count = count + 1 end
        assert.equals(2, count, "should register both Pos archetypes (Pos-only and Pos+Tag)")
    end)

    it("registers archetypes created after the registry was built", function()
        local world = tecs.newWorld()
        local registry = archetype_registry.new(world, {
            name = "test",
            matches = function(arch: tecs.Archetype): boolean
                return arch:get(Pos) ~= nil
            end,
            create = makeState,
        })

        -- No archetypes existed at registry creation time.
        local count = 0
        for _, _state in registry:archetypes() do count = count + 1 end
        assert.equals(0, count)

        world:spawn(Pos(1, 2))

        count = 0
        for _, _state in registry:archetypes() do count = count + 1 end
        assert.equals(1, count, "ArchetypeCreated should have triggered registration")
    end)

    it("attaches state as observer; mutations flow into onEntitiesAdded", function()
        local world = tecs.newWorld()
        local registry = archetype_registry.new(world, {
            name = "test",
            matches = function(arch: tecs.Archetype): boolean
                return arch:get(Pos) ~= nil
            end,
            create = makeState,
        })

        world:spawn(Pos(1, 2))

        -- Find the state for the Pos archetype.
        local state: any
        for _, s in registry:archetypes() do
            state = s
            break
        end
        assert.is_not_nil(state)

        local events = (state as {string:any}).events as {{string:any}}
        local sawAdded = false
        for _, ev in ipairs(events) do
            if ev.kind == "added" then sawAdded = true end
        end
        assert.is_true(sawAdded, "spawn should fire onEntitiesAdded on the registered observer")
    end)

    it("flushAll calls flush on every registered state", function()
        local world = tecs.newWorld()
        world:spawn(Pos(1, 1))
        world:spawn(Pos(2, 2), Tag)

        local registry = archetype_registry.new(world, {
            name = "test",
            matches = function(arch: tecs.Archetype): boolean
                return arch:get(Pos) ~= nil
            end,
            create = makeState,
        })

        registry:flushAll()

        local flushedCount = 0
        for _, state in registry:archetypes() do
            for _, ev in ipairs((state as {string:any}).events as {{string:any}}) do
                if ev.kind == "flushed" then flushedCount = flushedCount + 1 end
            end
        end
        assert.equals(2, flushedCount, "flushAll should call flush on each state once")
    end)

    it("removes state from tracking when archetype is destroyed", function()
        local world = tecs.newWorld()
        local registry = archetype_registry.new(world, {
            name = "test",
            matches = function(arch: tecs.Archetype): boolean
                return arch:get(Pos) ~= nil
            end,
            create = makeState,
        })

        world:spawn(Pos(1, 2))

        -- Find the archetype and trigger destruction directly.
        local arch: tecs.Archetype = nil
        for a, _ in registry:archetypes() do arch = a end
        assert.is_not_nil(arch);

        (arch as {string:any}):notifyArchetypeDestroyed()

        -- After destruction, the archetype should be unregistered.
        local stillRegistered = false
        for a, _ in registry:archetypes() do
            if a == arch then stillRegistered = true end
        end
        assert.is_false(stillRegistered, "destroyed archetype must be removed from registry")
    end)
end)
