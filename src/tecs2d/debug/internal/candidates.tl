--- Live completion candidate sources for debugger command schemas.

local tecs <const> = require("tecs")
local componentregistry <const> = require("tecs.internal.components")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local logtap <const> = require("tecs2d.internal.logtap")
local gfxtypes <const> = require("tecs2d.gfx.types")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local breakpoints <const> = require("tecs2d.debug.internal.breakpoints")

local record candidates
    build: function(
        world: tecs.World,
        ctx: debugcontext.Context,
        pipeline: function(): gfxtypes.Pipeline,
        commandNames: function(): {string},
        selectionTarget: string
    ): function(string): {string}
end

local function markedNames(ctx: debugcontext.Context): {string}
    local names: {string} = {}
    for _, name in pairs(ctx.marks) do names[#names + 1] = name end
    table.sort(names)
    local out: {string} = {}
    local last: string = nil
    for i = 1, #names do
        if names[i] ~= last then
            out[#out + 1] = names[i]
            last = names[i]
        end
    end
    return out
end

function candidates.build(world: tecs.World, ctx: debugcontext.Context,
        pipeline: function(): gfxtypes.Pipeline,
        commandNames: function(): {string},
        selectionTarget: string): function(string): {string}
    return function(source: string): {string}
        local out: {string} = {}
        if source == "commands" then
            return commandNames()
        elseif source == "components" then
            for name in pairs(componentregistry.registeredComponents) do
                out[#out + 1] = name
            end
        elseif source == "breakpointselectors" then
            return breakpoints.completionCandidates(world)
        elseif source == "breakpointids" then
            local manager = world.resources[breakpoints.KEY]
            if manager then
                for i = 1, #manager.entries do
                    out[#out + 1] = tostring(manager.entries[i].id)
                end
            end
            return out
        elseif source == "marks" or source == "targets"
                or source == "edittargets" then
            if source == "edittargets" then out[#out + 1] = selectionTarget end
            local names = markedNames(ctx)
            for i = 1, #names do out[#out + 1] = names[i] end
            return out
        elseif source == "bundles" then
            for name in pairs(world:getBundles()) do out[#out + 1] = name end
        elseif source == "systems" then
            local infos = systemcontrol.list(world)
            for i = 1, #infos do out[#out + 1] = infos[i].name end
        elseif source == "cameras" then
            local current = pipeline()
            local registered = current
                and (current as {string: any})._cameras as {gfxtypes.Camera}
            if registered then
                for i = 1, #registered do
                    local name = registered[i]:getName()
                    if name ~= "" then out[#out + 1] = name end
                end
            end
        elseif source == "loggers" then
            return logtap.loggers()
        else
            return out
        end
        table.sort(out)
        return out
    end
end

return candidates
