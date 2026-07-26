--- The ECS half, for engine code.
---
--- Games require `tecs` and get everything. Engine modules require this
--- instead, because `tecs` is the aggregator that pulls them in: a module the
--- surface exports cannot also depend on the surface.
---
--- So the rule is one direction. Internal code depends on a half; only a game
--- depends on the whole. This carries what the engine actually uses rather
--- than the whole ECS API, so the dependency stays legible.

local types <const> = require("tecs.types")
local components <const> = require("tecs.internal.components")
local builtins <const> = require("tecs.internal.builtins")
local phases <const> = require("tecs.internal.phases")
local WorldImpl <const> = require("tecs.internal.world")

local record ecs
    type World = types.World
    type Component = types.components.Component
    type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
    type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
    type Query = types.Query
    type Archetype = types.Archetype

    phases: phases
    builtins: builtins

    newWorld: function(config?: types.World.Config): World
    newComponent: function<C is Component>(options: ComponentOptions<C>): C
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C
end

ecs.phases = phases
ecs.builtins = builtins
ecs.newWorld = WorldImpl.new
-- Cast, because Teal does not accept bare assignment of these polymorphic
-- function values between record fields even when the signatures match.
ecs.newComponent = components.newComponent
    as function<C is types.components.Component>(options: types.components.ComponentOptions<C>): C
ecs.newFFIComponent = components.newFFIComponent
    as function<C is types.components.Component>(options: types.components.FFIComponentOptions<C>): C

return ecs
