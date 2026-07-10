--- Love Interop Example
--- Demonstrates GPU shapes (circles, rectangles) and CPU text drawing
--- with proper depth interleaving using the Draw phase.
--- All entities bounce vertically and Y-sort against each other.
--- A moving light sweeps across the scene to show lighting on both GPU and CPU draws.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local lg <const> = love.graphics
local sin <const> = math.sin
local cos <const> = math.cos
local pi <const> = math.pi

-- Enable MCP server

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local Transform <const> = tecs.builtins.Transform

--- Bouncing behavior component
local record Bouncer is tecs.Component
    speed: number      -- Bounce speed multiplier
    amplitude: number  -- Bounce height in pixels
    phase: number      -- Phase offset for varied timing
    baseY: number      -- Starting Y position
    metamethod __call: function(self, speed: number, amplitude: number, phase: number, baseY: number): Bouncer
end

tecs.newComponent({
    name = "Bouncer",
    container = Bouncer,
    fields = {"speed", "amplitude", "phase", "baseY"},
    init = function(instance: Bouncer, speed: number, amplitude: number, phase: number, baseY: number)
        instance.speed = speed
        instance.amplitude = amplitude
        instance.phase = phase
        instance.baseY = baseY
    end
})

--- Text label component (for CPU-rendered text)
local record TextLabel is tecs.Component
    text: string
    font: love.graphics.Font
    metamethod __call: function(self, text: string, font: love.graphics.Font): TextLabel
end

tecs.newComponent({
    name = "TextLabel",
    container = TextLabel,
    fields = {"text", "font"},
    init = function(instance: TextLabel, text: string, font: love.graphics.Font)
        instance.text = text
        instance.font = font
    end
})

-------------------------------------------------------------------------------
-- Game
-------------------------------------------------------------------------------

local function loveInteropPlugin(world: tecs.World)
    -- Add MCP plugin for debugging
    world:addPlugin(mcp.new())

    -- Add stats plugin (F1 to toggle)
    world:addPlugin(require("tecs2d.debug").new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    local fontSmall = lg.newFont(14)
    local fontMedium = lg.newFont(20)
    local fontLarge = lg.newFont(28)

    -- Screen dimensions (virtual)
    local screenW = 600
    local screenH = 450
    local centerX = screenW / 2
    local centerY = screenH / 2

    -- Add a moving light that orbits the center
    local Light <const> = gfx.Light
    local lightEntity = world:spawn(
        Transform(centerX, centerY, 0, 1),
        Light(400, 1.2, 1.0, 0.9, 0.7)
    )

    -- Spawn GPU circles at different positions with different bounce params
    for i = 1, 5 do
        local x = 50 + (i - 1) * 120
        local baseY = centerY
        local speed = 0.02 + i * 0.008
        local radius = 8 + i * 2
        local amplitude = centerY - radius * 2
        local phase = i * 0.5
        local scale = 0.5 + i * 0.15

        world:spawn(
            Transform(x, baseY, 0, 1, 0, scale, scale),
            gfx.Circle(radius),
            gfx.Color(1, 0.3 + i * 0.15, 0.2, 1),
            Bouncer(speed, amplitude, phase, baseY)
        )
    end

    -- Spawn GPU rectangles (same layer as circles for Y-based depth sorting)
    for i = 1, 4 do
        local x = 80 + (i - 1) * 140
        local baseY = centerY
        local speed = 0.025 + i * 0.008
        local w = 15 + i * 3
        local h = 10 + i * 2
        local amplitude = centerY - h
        local phase = i * 0.7 + 1.0
        local scale = 0.6 + i * 0.1

        world:spawn(
            Transform(x, baseY, 0, 1, 0, scale, scale),
            gfx.Rectangle(w, h),
            gfx.Color(0.2, 0.4 + i * 0.1, 1, 1),
            Bouncer(speed, amplitude, phase, baseY)
        )
    end

    -- Spawn text labels (same layer for Y-based depth sorting with GPU shapes)
    local texts = {"Hello", "World", "Tecs", "Love2D", "GPU+CPU"}
    local fonts = {fontSmall, fontMedium, fontLarge, fontMedium, fontSmall}
    for i = 1, #texts do
        local x = 40 + (i - 1) * 110
        local baseY = centerY
        local speed = 0.015 + i * 0.006
        local textH = fonts[i]:getHeight()
        local amplitude = centerY - textH
        local phase = i * 0.4 + 2.0
        local scale = 0.8 + i * 0.1

        world:spawn(
            Transform(x, baseY, 0, 1, 0, scale, scale),
            TextLabel(texts[i], fonts[i]),
            Bouncer(speed, amplitude, phase, baseY)
        )
    end

    -- Query for bouncers
    local bouncerQuery = world:query({ name = "Bouncers", include = {Transform, Bouncer} })

    -- Query for text labels
    local textQuery = world:query({ name = "TextLabels", include = {Transform, TextLabel, Bouncer} })

    -- Update system: animate bouncing + move the light
    local time = 0.0
    world:addSystem({
        name = "BounceUpdate",
        phase = tecs.phases.Update,
        run = function(dt: number)
            time = time + dt

            for archetype, len in bouncerQuery:iter() do
                local transforms = archetype:getMut(Transform)
                local bouncers = archetype:get(Bouncer)

                for i = 1, len do
                    local t = transforms[i]
                    local b = bouncers[i]

                    -- Sinusoidal bounce
                    local bounce = sin((time * b.speed + b.phase) * pi * 2) * b.amplitude
                    t.y = b.baseY + bounce
                end
            end

            -- Orbit the light around the center
            local lightTransform = world:get(lightEntity, Transform)
            lightTransform.x = centerX + cos(time * 0.5) * 200
            lightTransform.y = centerY + sin(time * 0.5) * 100
        end
    })

    -- Draw phase system: draw text with proper depth interleaving
    -- CPU-drawn text depth-sorts correctly alongside GPU circles and rectangles
    local colors <const>: {{number}} = {
        {1, 1, 0.6, 1},    -- Yellow
        {1, 0.2, 0.8, 1},  -- Magenta
        {0.4, 1, 0.4, 1},  -- Green
        {0.5, 0.8, 1, 1},  -- Sky blue
        {1, 0.6, 0.3, 1},  -- Orange
    }
    world:addSystem({
        name = "RenderText",
        phase = tecs.phases.Draw,
        run = function(_dt: number)
            local textIndex = 0
            for archetype, len in textQuery:iter() do
                local transforms = archetype:get(Transform)
                local labels = archetype:get(TextLabel)

                for i = 1, len do
                    textIndex = textIndex + 1
                    local t = transforms[i]
                    local label = labels[i]

                    -- Get text dimensions for visibility check
                    local font = label.font
                    local textW = font:getWidth(label.text) * t.scaleX
                    local textH = font:getHeight() * t.scaleY

                    -- Check visibility
                    if pipeline:getCamera():isVisible(t.x, t.y, textW, textH) then
                        -- Compute bottom Y for depth sorting
                        local bottomY = t.y + textH

                        pipeline:worldShader():at(t.layer, t.z, t.x, bottomY):attach()
                        local c = colors[(textIndex - 1) % #colors + 1]
                        lg.setColor(c[1], c[2], c[3], c[4])

                        -- Set font and draw text
                        lg.setFont(font)
                        lg.print(label.text, t.x, t.y, 0, t.scaleX, t.scaleY)
                    end
                end
            end

            -- Detach shader once at end (optimized - only detaches if active)
            pipeline:detachWorldShader()

            -- Reset color
            lg.setColor(1, 1, 1, 1)
        end
    })

    -- Input handling
    -- Center camera
    pipeline:getCamera():setPosition(centerX, centerY)
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        loveInteropPlugin(world)
    end,
    render = {
        virtualHeight = 450,
        ambientLight = {0.08, 0.08, 0.12},
    },
})
