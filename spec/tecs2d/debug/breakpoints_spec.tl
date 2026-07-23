require("busted")
local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")
local breakpoints <const> = require("tecs2d.debug.internal.breakpoints")
local suspension <const> = require("tecs2d.internal.suspension")

local Foo <const> = tecs.newTagComponent({name = "BreakpointSpecFoo"})
local Bar <const> = tecs.newTagComponent({name = "BreakpointSpecBar"})

local function newManager(): tecs.World, breakpoints.Manager,
    suspension.Controller
    local world = tecs.newWorld()
    local controller = suspension.ensure(world)
    local manager = breakpoints.new(world, controller)
    return world, manager, controller
end

describe("debugger breakpoints", function()
    it("compiles AND branches, alternatives, OR, and quoted states", function()
        local selector, err = breakpoints.parse(
            'has=BreakpointSpecFoo lacks=BreakpointSpecBar '
            .. '|| pushed="some state"|Pause state=Pause')
        luassert.is_nil(err)
        luassert.equals(2, #selector.branches)
        luassert.is_false(selector.branches[1].stateTransition)
        luassert.is_true(selector.branches[2].stateTransition)
        luassert.equals("some state",
            selector.branches[2].terms[1].values[1])
    end)

    it("rejects unknown keys, components, and mixed transition domains",
        function()
            local selector, err = breakpoints.parse("maybe=Foo")
            luassert.is_nil(selector)
            luassert.matches("unknown selector key", err)

            selector, err = breakpoints.parse("has=DefinitelyMissing")
            luassert.is_nil(selector)
            luassert.matches("unknown component", err)

            selector, err = breakpoints.parse(
                "has=BreakpointSpecFoo pushed=Pause")
            luassert.is_nil(selector)
            luassert.matches("cannot share an AND branch", err)
        end)

    it("matches set entry, component removal, and lifecycle transitions",
        function()
            local world, manager = newManager()
            local entering = assert(manager:add(
                "has=BreakpointSpecFoo lacks=BreakpointSpecBar"))
            local removed = assert(manager:add("removed=BreakpointSpecBar"))
            local despawn = assert(manager:add("life=despawn"))

            local id = world:spawn(Foo, Bar)
            luassert.is_nil(manager:consume())
            world:remove(id, Bar)
            local trigger = manager:consume()
            luassert.equals(entering.id, trigger.breakpointId)
            luassert.equals(id, trigger.entity)
            luassert.equals(1, entering.hits)
            luassert.equals(1, removed.hits)

            world:despawn(id)
            trigger = manager:consume()
            luassert.equals(despawn.id, trigger.breakpointId)
            luassert.equals("despawn", trigger.description)
        end)

    it("matches batch structural changes without affecting disabled worlds",
        function()
            local world, manager = newManager()
            local entry = assert(manager:add("added=BreakpointSpecBar"))
            world:spawn(Foo)
            world:spawn(Foo)
            manager:consume()

            local query = world:query({all = {Foo}})
            world:batchSet(query, Bar)
            local trigger = manager:consume()
            luassert.equals(entry.id, trigger.breakpointId)
            luassert.equals(2, entry.hits)

            manager:setEnabled(entry.id, false)
            luassert.is_nil(
                (world as internal.WorldImpl)._transitionObserver)
        end)

    it("matches committed deferred changes and ignores net-zero changes",
        function()
            local world, manager = newManager()
            local entry = assert(manager:add("added=BreakpointSpecBar"))
            local id = world:spawn(Foo)
            manager:consume()

            world:defer()
            world:set(id, Bar)
            world:commit()
            luassert.equals(entry.id, manager:consume().breakpointId)

            local second = world:spawn(Foo)
            manager:consume()
            world:defer()
            world:set(second, Bar)
            world:remove(second, Bar)
            world:commit()
            luassert.is_nil(manager:consume())
            luassert.equals(1, entry.hits)
        end)

    it("treats clearEntities as entity despawns", function()
        local world, manager = newManager()
        local entry = assert(manager:add("life=despawn"))
        world:spawn(Foo)
        world:spawn(Bar)
        manager:consume()

        world:clearEntities()
        local trigger = manager:consume()
        luassert.equals(entry.id, trigger.breakpointId)
        luassert.equals(2, entry.hits)
    end)

    it("matches pushed and popped states using the resulting active state",
        function()
            local world, manager = newManager()
            world:createState("Gameplay")
            world:createState("Pause")
            world:pushState("Gameplay")

            local pushed = assert(manager:add(
                "pushed=Pause state=Pause"))
            local popped = assert(manager:add(
                "popped=Pause state=Gameplay"))

            world:pushState("Pause")
            local trigger = manager:consume()
            luassert.equals(pushed.id, trigger.breakpointId)
            luassert.equals("pushed Pause", trigger.description)

            world:popState()
            trigger = manager:consume()
            luassert.equals(popped.id, trigger.breakpointId)
            luassert.equals("popped Pause", trigger.description)
        end)
end)
