local events <const> = require("tecs2d.internal.events")
local input <const> = require("tecs2d.internal.input")
local handlers <const> = require("tecs2d.internal.handlers")
local stats <const> = require("tecs2d.internal.stats")
local tecs <const> = require("tecs")

local lg_origin <const> = love.graphics.origin
local lg_clear <const> = love.graphics.clear
local lg_present <const> = love.graphics.present
local lg_isActive <const> = love.graphics.isActive
local lg_getBackgroundColor <const> = love.graphics.getBackgroundColor

local love_timer_step <const> = love.timer.step

--- Integrates Love2D with Tecs.
local record love2d
    --- Love2D events.
    events: events

    --- The input module provides global input state for Love2D.
    input: input

    --- The stats module provides a way to see debug information about the game.
    stats: stats

    --- Creates a function that runs the game loop.
    --- @param timestep The time between each frame in frames/second. Defaults to 1/60.
    --- @param gamePlugin The game plugin to run.
    --- @return A function that runs the game loop. Return this function from `love.run`.
    run: function(timestep: number, gamePlugin: tecs.Plugin): (function(): string | number)

    --- Triggers a quit event to exit the application cleanly.
    --- @param exitCode Optional exit code (defaults to 0 for success).
    quit: function(exitCode: number)
end

-- Setup the re-exports.
love2d.input = input
love2d.events = events
love2d.stats = stats

-------------------------------------------------------------------------------
-- love2d plugin
-------------------------------------------------------------------------------

local function love2dPlugin(world: tecs.World)

    world:addSystem({
        phase = tecs.phases.RenderFirst,
        run = function()
            if lg_isActive() then
                lg_origin()
                lg_clear(lg_getBackgroundColor())
            end
        end
    })

    -- Still allow the use of love.draw.
    if love.draw then
        world:addSystem({
            phase = tecs.phases.Render,
            run = love.draw
        })
    end

    world:addSystem({
        phase = tecs.phases.RenderLast,
        run = function()
            if lg_isActive() then
                lg_present()
            end
        end
    })

    -- We don't want the first frame's dt to include time taken by love.load.
    world:addSystem({
        phase = tecs.phases.PostStartup,
        run = love.timer.step
    })

    -- Mark when entering fixed phases
    world:addSystem({
        phase = tecs.phases.FixedFirst,
        run = function()
            input.enterFixedPhase()
        end
    })

    -- Mark exit from fixed phases and clear latched events
    world:addSystem({
        phase = tecs.phases.FixedLast,
        run = function()
            input.exitFixedPhase()
        end
    })

    -- Still allow the use of love.update.
    if love.update then
        world:addSystem({
            phase = tecs.phases.Update,
            run = love.update
        })
    end
end

-------------------------------------------------------------------------------
-- love2d main run function implementation
-------------------------------------------------------------------------------

function love2d.run(timestep: number, gamePlugin: tecs.Plugin): (function(): number | string)
    assert(gamePlugin, "gamePlugin is required")
    assert(timestep and timestep > 0, "timestep must be a positive number")
    if (love.load) then
        love.load(love.arg.parseGameArguments(arg), arg)
    end

    local world <const> = tecs.newWorld({timestep = timestep})
    world:addPlugin(love2dPlugin)
    world:addPlugin(gamePlugin)

    local eventPoller <const> = handlers.pollEvents(world)

    local quitEventReceived: integer = nil
    world:observe(events.Quit, function(e: events.Quit)
        quitEventReceived = e.exitstatus
    end)

    world:startup()

    return function(): integer | string
        local dt = love_timer_step()
        eventPoller(dt, world)

        -- see https://www.gafferongames.com/post/fix_your_timestep/
        if dt > 0.25 then
            dt = 0.25
        end

        world:update(dt)

        if quitEventReceived then
            world:shutdown()
            return quitEventReceived
        end

        -- Sleep 1 ms to reclaim some CPU time, but only if the game can keep up with the target FPS.
        if timestep - dt > 0 then
            love.timer.sleep(0.001)
        end
    end
end

--- Triggers a quit event to exit the application cleanly.
function love2d.quit(exitCode: number)
    exitCode = exitCode or 0
    love.event.push("quit", exitCode)
end

return love2d
