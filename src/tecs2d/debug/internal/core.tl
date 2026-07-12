--- Headless debugger core: the shared DebugContext, freeze controller,
--- annotations store, recorder, and command registry, plus the always-on
--- systems that keep the registry's stateful commands working with no overlay
--- (rewind ring capture, delayed screenshots, recording frame capture and
--- shutdown). The overlay layers the human surface (input, drawing, menus)
--- on top; the MCP plugin ensures the core so debug_* tools exist in every
--- session.

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")
local freeze <const> = require("tecs2d.debug.internal.freeze")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local rewind <const> = require("tecs2d.debug.internal.rewind")
local commands <const> = require("tecs2d.debug.commands")

local getTime <const> = love.timer.getTime

local record core
    --- Recording defaults for the shared recorder (ffmpegPath, outputDir,
    --- countdown, fps, scale, frameFormat, ringSize).
    type Options = recording.Options

    --- Get or create the headless debugger core: context, registry, freeze,
    --- annotations, recorder, rewind; works without the overlay. Idempotent
    --- (keyed on the command registry resource). A later call with non-nil
    --- opts reconfigures the existing recorder: exactly the fields present in
    --- opts overwrite its defaults (the debug plugin installing after the MCP
    --- plugin applies its recording config this way). Returns the registry;
    --- its env carries the context, recorder, freeze controller, and
    --- annotations store.
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
    local fz = freeze.ensure(w)
    local store = annotations.install(w, ctx)
    local recorder = recording.new(ctx, opts)
    w.resources[recording.KEY] = recorder
    local registry = commands.build({
        world = w,
        ctx = ctx,
        recorder = recorder,
        freeze = fz,
        annotations = store,
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
            rewind.tick(ctx, w, now, fz:isFrozen())

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
        end,
    })

    w:addSystem({
        name = "debug.RecordingShutdown",
        phase = tecs.phases.PreShutdown,
        run = function()
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
