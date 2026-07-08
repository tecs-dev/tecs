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

local record layout_dirty
    --- Merge components into the world's watch set and install the
    --- frame-end sampler on first use.
    watch: function(world: tecs.World, components: {tecs.Component})

    --- True when a watched column is dirty now, or was dirty at the end
    --- of the previous frame.
    changed: function(world: tecs.World): boolean
end

local record WorldState
    watched: {tecs.Component: boolean}
    pending: boolean
    installed: boolean
end

local states <const>: {tecs.World: WorldState} =
    setmetatable({}, {__mode = "k"} as metatable<{tecs.World: WorldState}>)

local function stateFor(world: tecs.World): WorldState
    local state = states[world]
    if not state then
        state = {watched = {}, pending = false, installed = false}
        states[world] = state
    end
    return state
end

local function scan(world: tecs.World, watched: {tecs.Component: boolean}): boolean
    for arch in world:dirtyArchetypes() do
        local cols = arch.columns
        for comp in pairs(watched) do
            if cols[comp] ~= nil then
                return true
            end
        end
    end
    return false
end

function layout_dirty.watch(world: tecs.World, components: {tecs.Component})
    local state = stateFor(world)
    for i = 1, #components do
        state.watched[components[i]] = true
    end
    if not state.installed then
        state.installed = true
        -- New watchers must run once against existing state.
        state.pending = true
        world:addSystem({
            name = "ui.LayoutDirtySampler",
            phase = tecs.phases.RenderLast,
            run = function()
                state.pending = scan(world, state.watched)
            end,
        })
    end
end

function layout_dirty.changed(world: tecs.World): boolean
    local state = stateFor(world)
    return state.pending or scan(world, state.watched)
end

return layout_dirty
