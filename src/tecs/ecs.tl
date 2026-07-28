--- The ECS half, for engine code.
---
--- Games require `tecs` and get everything. Engine modules require this
--- instead, because `tecs` is the aggregator that pulls them in: a module the
--- surface exports cannot also depend on the surface.
---
--- So the rule is one direction. Internal code depends on a half; only a game
--- depends on the whole. This carries what the engine actually uses rather
--- than the whole ECS API, so the dependency stays legible.

-- First, as in the whole surface. `componentcodegen` captures `table.unpack`
-- when it loads, and on this interpreter that name only exists once this has
-- run. Requiring the halves in either order has to work, and this half is what
-- a tool reaching for the ECS alone requires.
require("tecs.internal.compat")

local types <const> = require("tecs.types")
local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local builtins <const> = require("tecs.internal.builtins")
local phases <const> = require("tecs.internal.phases")
local WorldImpl <const> = require("tecs.internal.world")

local record ecs
    type World = types.World
    type Component = types.components.Component
    type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
    type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
    type Event = types.events.Event
    type Plugin = types.Plugin
    type Query = types.Query
    type Archetype = types.Archetype
    type FixedOverload = types.FixedOverload

    phases: phases
    builtins: builtins

    newWorld: function(config?: types.World.Config): World
    newComponent: function<C is Component>(options: ComponentOptions<C>): C
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C
    newEvent: function<E is Event>(event: E)

    --- The component registered under `name`, or nil.
    ---
    --- The registry is process-wide, because a component's id is allocated
    --- once at registration and every world that carries one agrees on it. So
    --- this answers what can be named, and a world answers what is present.
    ---
    --- Finds a dense relationship instance by its stamped name as well, which
    --- `declaredComponents` leaves out.
    componentByName: function(name: string): Component

    --- Every component declared in this process, name to component.
    ---
    --- A fresh table per call, so the registry itself stays unwritable from
    --- outside registration.
    ---
    --- Dense relationship instances are left out. One is registered per target
    --- under a stamped `Rel->42` name, so a world with many edges has many of
    --- them, and none of them is a component anybody declared.
    declaredComponents: function(): {string: Component}
end

ecs.phases = phases
ecs.builtins = builtins
ecs.newWorld = WorldImpl.new
ecs.newEvent = events.newEvent
-- Cast, because Teal does not accept bare assignment of these polymorphic
-- function values between record fields even when the signatures match.
ecs.newComponent = components.newComponent as function<C is types.components.Component>(
    options: types.components.ComponentOptions<C>
): C
ecs.newFFIComponent = components.newFFIComponent as function<C is types.components.Component>(
    options: types.components.FFIComponentOptions<C>
): C

function ecs.componentByName(name: string): types.components.Component
    return components.registeredComponents[name]
end

function ecs.declaredComponents(): {string: types.components.Component}
    local declared: {string: types.components.Component} = {}
    for name, component in pairs(components.registeredComponents) do
        if component.wildcardContainer == nil then
            declared[name] = component
        end
    end
    return declared
end

return ecs
