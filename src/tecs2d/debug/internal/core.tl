--- Headless debugger core: the shared DebugContext, freeze controller,
--- recorder, command registry, and private diagnostic visuals, plus the always-on
--- systems that keep the registry's stateful commands working with no overlay
--- (rewind ring capture, delayed screenshots, recording frame capture and
--- shutdown). The overlay layers the human surface (input, drawing, menus)
--- on top; the MCP plugin ensures the core so cmd_* tools exist in every
--- session.

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local breakpoints <const> = require("tecs2d.debug.internal.breakpoints")
local recording <const> = require("tecs2d.debug.internal.recording")
local suspension <const> = require("tecs2d.internal.suspension")
local visuals <const> = require("tecs2d.debug.internal.visuals")
local rewind <const> = require("tecs2d.debug.internal.rewind")
local commands <const> = require("tecs2d.debug.commands")

local getTime <const> = love.timer.getTime

local record core
    --- Recording defaults for the shared recorder (ffmpegPath, outputDir,
    --- countdown, fps, scale, frameFormat, ringSize).
    type Options = recording.Options

    --- Get or create the headless debugger core: context, registry, freeze,
    --- recorder, rewind, and diagnostic visuals; works without the overlay. Idempotent
    --- (keyed on the command registry resource). A later call with non-nil
    --- opts reconfigures the existing recorder: exactly the fields present in
    --- opts overwrite its defaults (the debug plugin installing after the MCP
    --- plugin applies its recording config this way). Returns the registry;
    --- its env carries the context, recorder, and freeze controller.
    ensure: function(w: tecs.World, opts?: Options): commands.Registry
end

function core.ensure(w: tecs.World, opts?: core.Options): commands.Registry
    local existing = w.resources[commands.KEY]
    if existing then
        if opts then
            existing.env.recorder:configure(opts)
        end
        return existing
    end

    local ctx = debugcontext.new()
    w.resources[debugcontext.KEY] = ctx
    local controller = suspension.ensure(w)
    local breakpointManager = breakpoints.new(w, controller)
    w.resources[breakpoints.KEY] = breakpointManager
    visuals.install(w, ctx)
    local recorder = recording.new(ctx, opts)
    w.resources[recording.KEY] = recorder
    local registry = commands.build({
        world = w,
        ctx = ctx,
        recorder = recorder,
        suspension = controller,
        keys = {leader = "ctrl", debugToggle = "/", statsToggle = "."},
    })
    w.resources[commands.KEY] = registry

    -- Wall-clock duties that must run every frame, overlay or not.
    -- RenderFirst so they keep running while frozen.
    local tickLastAt = getTime()
    w:addSystem({
        name = "debug.CoreTick",
        phase = tecs.phases.RenderFirst,
        run = function()
            local now = getTime()
            local frameDt = now - tickLastAt
            tickLastAt = now

            -- Time-travel ring capture: wall-clock interval, and never while
            -- the freeze controller is held (whoever holds it).
            rewind.tick(ctx, w, now, controller:isSuspended())

            -- Delayed screenshots count down on wall-clock time and fire even
            -- while the panel is closed or the game is frozen.
            for i = #registry.pendingShots, 1, -1 do
                local shot = registry.pendingShots[i]
                shot.dueIn = shot.dueIn - frameDt
                if shot.dueIn <= 0 then
                    table.remove(registry.pendingShots, i)
                    shot.fire()
                end
            end

            -- Timed profiles auto-finish on their wall-clock deadline even
            -- with no overlay; the overlay's input system consumes
            -- registry.profileResult to show the results popup.
            local prof = registry.profiler
            if prof.session and prof.deadline > 0 and now >= prof.deadline then
                registry.profileResult = registry:finishProfile()
            end

            local trigger = breakpointManager:consume()
            if trigger then
                ctx.frozen = true
                if trigger.entity and w:isAlive(trigger.entity) then
                    ctx.selected = {trigger.entity}
                end
                debugcontext.pushEvent(ctx, "breakpoint", {
                    id = trigger.breakpointId,
                    selector = trigger.selector,
                    entity = trigger.entity,
                    transition = trigger.description,
                })
                local popup = {
                    "Selector",
                    "  " .. trigger.selector,
                    "",
                    "Transition",
                    "  " .. trigger.description,
                }
                if trigger.entity then
                    popup[#popup + 1] = ""
                    popup[#popup + 1] = "Entity"
                    popup[#popup + 1] = "  #" .. tostring(trigger.entity)
                end
                registry.breakpointResult = {
                    ok = true,
                    popupTitle = "Breakpoint #" .. tostring(
                        trigger.breakpointId),
                    popup = popup,
                    popupClosable = true,
                    data = {
                        breakpointId = trigger.breakpointId,
                        selector = trigger.selector,
                        entity = trigger.entity,
                        transition = trigger.description,
                    },
                }
            end
        end,
    })

    w:addSystem({
        name = "debug.RecordingShutdown",
        phase = tecs.phases.PreShutdown,
        run = function()
            breakpointManager:detach()
            recorder:shutdown()
        end,
    })

    -- Frame capture for the permission-free "frames" recording backend. Runs
    -- every frame regardless of overlay visibility, grabbing the finished frame
    -- after the world has rendered (PostRender) and before present.
    w:addSystem({
        name = "debug.RecordingCapture",
        phase = tecs.phases.PostRender,
        run = function()
            recorder:captureFrame()
        end,
    })

    return registry
end

return core
