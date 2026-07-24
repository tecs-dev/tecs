--- Carryover dirty tracking for the layout systems' dirty gates.
---
--- Component-dirty bits clear at the end of each world update, but the
--- layout systems run in PostUpdate; a mutation made after that (MCP
--- run_lua in RenderFirst, render callbacks) would be wiped before the
--- gates ever see it. A RenderLast sampler snapshots "was any watched
--- column dirty at frame end" so next frame's gates honor it.
---
--- Consumers call `watch` at plugin install (merging their component
--- set) and `changed` inside their gate. The sampler overwrites the
--- pending flag each frame, so a settled hierarchy converges to closed
--- gates one frame after the last real change.

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")

local record layout_dirty
    record Watch
        watched: {tecs.Component: boolean}
        pending: boolean
    end

    --- Merge components into a named watch and install the frame-end
    --- sampler on first use. Consumers that intentionally share an
    --- invalidation domain use the same name.
    watch: function(
        world: tecs.World,
        name: string,
        components: {tecs.Component}
    ): Watch

    --- True when one of this watch's columns is dirty now, or was dirty
    --- at the end of the previous frame.
    changed: function(world: tecs.World, watch: Watch): boolean
end

local record WorldState
    watches: {layout_dirty.Watch}
    watchByName: {string: layout_dirty.Watch}
    installed: boolean
end

local states <const>: {tecs.World: WorldState} =
    setmetatable({}, {__mode = "k"} as metatable<{tecs.World: WorldState}>)

local function stateFor(world: tecs.World): WorldState
    local state = states[world]
    if not state then
        state = {watches = {}, watchByName = {}, installed = false}
        states[world] = state
    end
    return state
end

local function scan(world: tecs.World, watched: {tecs.Component: boolean}): boolean
    local worldImpl <const> = world as tecsInternal.WorldImpl
    for arch in worldImpl:dirtyArchetypes() do
        for comp in pairs(watched) do
            if arch:isComponentDirty(comp) then
                return true
            end
        end
    end
    return false
end

function layout_dirty.watch(
    world: tecs.World,
    name: string,
    components: {tecs.Component}
): layout_dirty.Watch
    local state = stateFor(world)
    local watch = state.watchByName[name]
    if not watch then
        watch = {watched = {}, pending = true}
        state.watchByName[name] = watch
        state.watches[#state.watches + 1] = watch
    end
    for i = 1, #components do
        watch.watched[components[i]] = true
    end
    if not state.installed then
        state.installed = true
        world:addSystem({
            name = "ui.LayoutDirtySampler",
            phase = tecs.phases.RenderLast,
            run = function()
                for i = 1, #state.watches do
                    local item = state.watches[i]
                    item.pending = scan(world, item.watched)
                end
            end,
        })
    end
    return watch
end

function layout_dirty.changed(
    world: tecs.World,
    watch: layout_dirty.Watch
): boolean
    return watch.pending or scan(world, watch.watched)
end

return layout_dirty
