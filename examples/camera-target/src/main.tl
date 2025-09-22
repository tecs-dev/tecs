--- Camera Target Demo
--- Demonstrates CameraTarget dead zone and look-ahead features.
--- Keys 1-4 switch modes, WASD moves, Space shakes.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")
local floor <const> = require("floor")
local SpriteSheet <const> = require("tecs2d.gfx.internal.sprite.sheet").SpriteSheet

local lg <const> = love.graphics
local random <const> = math.random

local Transform <const> = tecs.builtins.Transform

local VIRTUAL_HEIGHT <const> = 360
local WORLD_W <const> = 2000
local WORLD_H <const> = 1500
local SPEED <const> = 150
local LANDMARK_COUNT <const> = 20
local FONT <const> = "assets/press-start-2p.fnt"

-- Mode configurations: { deadZoneW, deadZoneH, lookAheadX, lookAheadY, label }
local record ModeConfig
    dzW: number
    dzH: number
    laX: number
    laY: number
    label: string
end

local MODES <const>: {ModeConfig} = {
    { dzW = 0,  dzH = 0,  laX = 0,  laY = 0,  label = "1: BASIC FOLLOW" },
    { dzW = 60, dzH = 40, laX = 0,  laY = 0,  label = "2: DEAD ZONE" },
    { dzW = 0,  dzH = 0,  laX = 40, laY = 25, label = "3: LOOK-AHEAD" },
    { dzW = 60, dzH = 40, laX = 15, laY = 10, label = "4: BOTH" },
}

local function cameraTargetPlugin(world: tecs.World)
    world:addPlugin(stats.newStatsPlugin())
    world:addPlugin(mcp.new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    local cam = pipeline:getCamera()
    cam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
    cam:setShakeIntensity(16)

    local screenW = lg.getWidth() as integer
    local screenH = lg.getHeight() as integer
    local pixelScale = screenH / VIRTUAL_HEIGHT
    local virtualWidth = math.floor(VIRTUAL_HEIGHT * screenW / screenH)

    ---------------------------------------------------------------------------
    -- World content
    ---------------------------------------------------------------------------

    floor.spawnCheckered(world, {
        worldWidth = WORLD_W + 512,
        worldHeight = WORLD_H + 512,
        tileSize = 200,
        layer = 1,
        offsetX = -256,
        offsetY = -256,
    })

    -- Scatter colored circle landmarks
    for _ = 1, LANDMARK_COUNT do
        local hue = random() * 6
        local r, g, b: number, number, number
        if hue < 1 then r, g, b = 1, hue, 0
        elseif hue < 2 then r, g, b = 2 - hue, 1, 0
        elseif hue < 3 then r, g, b = 0, 1, hue - 2
        elseif hue < 4 then r, g, b = 0, 4 - hue, 1
        elseif hue < 5 then r, g, b = hue - 4, 0, 1
        else r, g, b = 1, 0, 6 - hue end

        world:spawn(
            Transform(random(100, WORLD_W - 100), random(100, WORLD_H - 100), 0, 2),
            gfx.Circle(15 + random(10)),
            gfx.Color(r, g, b, 0.6)
        )
    end

    -- Spawn player
    local runnerSheet = SpriteSheet.fromFile("assets/running.png")
    local playerId = world:spawn(
        Transform(WORLD_W / 2, WORLD_H / 2, 0, 2, 0, 2, 2),
        gfx.Sprite.fromSheet(runnerSheet, "run", { centered = true }),
        gfx.Color(1, 1, 1, 1),
        gfx.CameraTarget.new({})
    )

    -- HUD: mode label (layer 16, virtual space)
    local hudId = world:spawn(
        Transform.new({ x = virtualWidth / 2, y = 12, layer = 16 }),
        gfx.Text(FONT, MODES[1].label, 0.8),
        gfx.Color(1, 1, 1, 0.9)
    )

    -- HUD: controls
    world:spawn(
        Transform.new({ x = virtualWidth / 2, y = VIRTUAL_HEIGHT - 8, layer = 16 }),
        gfx.Text(FONT, "[1-4] MODE  [WASD] MOVE  [SPACE] SHAKE", 0.7),
        gfx.Color(1, 1, 1, 0.5)
    )

    local currentMode = 1

    local function applyMode(m: integer)
        currentMode = m
        local cfg = MODES[m]
        local ct = world:get(playerId, gfx.CameraTarget)
        ct.deadZoneW = cfg.dzW
        ct.deadZoneH = cfg.dzH
        ct.lookAheadX = cfg.laX
        ct.lookAheadY = cfg.laY
        -- Reset look-ahead smoothing on mode switch
        ct._lookX = 0
        ct._lookY = 0
        -- Disable lerping for dead zone modes so the camera tracks the boundary precisely
        local hasDeadZone = cfg.dzW > 0 and cfg.dzH > 0
        cam:setLerpingEnabled(not hasDeadZone)
        -- Update HUD label
        local bt = world:get(hudId, gfx.Text)
        bt:setText(cfg.label)
    end

    ---------------------------------------------------------------------------
    -- Systems
    ---------------------------------------------------------------------------

    -- Player movement (FixedUpdate for consistent speed)
    local playerQuery <const> = world:query({
        name = "player",
        include = { Transform, gfx.CameraTarget },
    })

    world:addSystem({
        name = "PlayerMove",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            for archetype, len in playerQuery:iter() do
                local transforms = archetype:getMut(Transform)
                for i = 1, len do
                    local t = transforms[i]
                    if input.isKeyDown("w") or input.isKeyDown("up") then t.y = t.y - SPEED * dt end
                    if input.isKeyDown("s") or input.isKeyDown("down") then t.y = t.y + SPEED * dt end
                    if input.isKeyDown("a") or input.isKeyDown("left") then t.x = t.x - SPEED * dt end
                    if input.isKeyDown("d") or input.isKeyDown("right") then t.x = t.x + SPEED * dt end
                    -- Clamp to world bounds
                    if t.x < 0 then t.x = 0 end
                    if t.x > WORLD_W then t.x = WORLD_W end
                    if t.y < 0 then t.y = 0 end
                    if t.y > WORLD_H then t.y = WORLD_H end
                end
            end
        end,
    })

    -- Mode switching and teleport
    world:addSystem({
        name = "Controls",
        phase = tecs.phases.Update,
        run = function()
            if input.isKeyReleased("1") then applyMode(1) end
            if input.isKeyReleased("2") then applyMode(2) end
            if input.isKeyReleased("3") then applyMode(3) end
            if input.isKeyReleased("4") then applyMode(4) end

            if input.isKeyReleased("space") then
                cam:shake(1.0)
            end

            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
            end
        end,
    })

    -- Debug overlay: draw dead zone rectangle in PostRender (screen space)
    world:addSystem({
        name = "DeadZoneOverlay",
        phase = tecs.phases.PostRender,
        run = function()
            local cfg = MODES[currentMode]
            if cfg.dzW <= 0 or cfg.dzH <= 0 then return end

            local dzPixelW = cfg.dzW * pixelScale * 2
            local dzPixelH = cfg.dzH * pixelScale * 2
            local cx = screenW / 2 - dzPixelW / 2
            local cy = screenH / 2 - dzPixelH / 2

            lg.setColor(1, 1, 0, 0.3)
            lg.rectangle("fill", cx, cy, dzPixelW, dzPixelH)
            lg.setColor(1, 1, 0, 0.8)
            lg.setLineWidth(2)
            lg.rectangle("line", cx, cy, dzPixelW, dzPixelH)
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    game = cameraTargetPlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lerpingEnabled = true,
        lerpSpeed = 20,
        cameraPosition = {WORLD_W / 2, WORLD_H / 2},
        layers = {
            [1] = { name = "ground" },
            [2] = { name = "sprites" },
            [16] = { name = "hud", space = "virtual" },
        },
    },
})
