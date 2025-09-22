--- Multi-Camera Demo
--- Cycles between camera modes with TAB:
---   Mode 1: Normal view + minimap overlay + in-game TV
---   Mode 2: Split-screen with independent camera controls

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
local pi <const> = math.pi
local sin <const> = math.sin
local cos <const> = math.cos

local Transform <const> = tecs.builtins.Transform

local VIRTUAL_HEIGHT <const> = 360
local WORLD_W <const> = 3200
local WORLD_H <const> = 2400
local SPRITE_COUNT <const> = 100
local CAMERA_SPEED <const> = 400
local MINIMAP_W <const> = 200
local MINIMAP_H <const> = 150
local MINIMAP_MARGIN <const> = 10
local DIVIDER_WIDTH <const> = 2

-- In-game TV dimensions and position (world space)
local TV_W <const> = 300
local TV_H <const> = 225
local TV_BORDER <const> = 12
local TV_X <const> = 400
local TV_Y <const> = 400

local FONT <const> = "assets/press-start-2p.fnt"

-- Simple velocity component for wandering sprites
local record Velocity is tecs.Component
    vx: number
    vy: number
    metamethod __call: function(self, vx: number, vy: number): Velocity
end

tecs.newComponent({
    name = "Velocity",
    container = Velocity,
    fields = {"vx", "vy"},
    init = function(instance: Velocity, vx: number, vy: number)
        instance.vx = vx
        instance.vy = vy
    end
})

local function multiCamPlugin(world: tecs.World)
    world:addPlugin(stats.newStatsPlugin())
    world:addPlugin(mcp.new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    local screenW = lg.getWidth() as integer
    local screenH = lg.getHeight() as integer
    local pixelScale = screenH / VIRTUAL_HEIGHT
    local virtualWidth = math.floor(VIRTUAL_HEIGHT * screenW / screenH)

    ---------------------------------------------------------------------------
    -- Cameras
    ---------------------------------------------------------------------------

    -- Primary camera: world layers only
    local primaryCam = pipeline:getCamera()
    primaryCam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
    primaryCam:setClamp(true)
    primaryCam:setPosition(WORLD_W / 2, WORLD_H / 2)
    primaryCam:setLayerRange(1, 3)

    -- Minimap camera: world layers, render to texture
    local minimapPixelScale = MINIMAP_H / VIRTUAL_HEIGHT
    local zoomX = MINIMAP_W / WORLD_W
    local zoomY = MINIMAP_H / WORLD_H
    local minimapCam = pipeline:newCamera("minimap", {
        canvas = lg.newCanvas(MINIMAP_W, MINIMAP_H),
        lerpingEnabled = false,
        position = {WORLD_W / 2, WORLD_H / 2},
        zoom = math.min(zoomX, zoomY) / minimapPixelScale,
        layerRange = {1, 3},
    })

    -- Split-screen cameras: world layers only
    local halfW = math.floor(screenW / 2) - math.floor(DIVIDER_WIDTH / 2)

    local leftCam = pipeline:newCamera("left", {
        viewport = {0, 0, halfW, screenH},
        lerpingEnabled = true,
        lerpSpeed = 8,
        position = {WORLD_W * 0.3, WORLD_H / 2},
        layerRange = {1, 3},
    })
    leftCam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
    leftCam:setClamp(true)
    leftCam:setActive(false)

    local rightCam = pipeline:newCamera("right", {
        viewport = {halfW + DIVIDER_WIDTH, 0, halfW, screenH},
        lerpingEnabled = true,
        lerpSpeed = 8,
        position = {WORLD_W * 0.7, WORLD_H / 2},
        layerRange = {1, 3},
    })
    rightCam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
    rightCam:setClamp(true)
    rightCam:setActive(false)

    -- Overlay camera: virtual-space layers, render to texture, composited in PostRender
    local overlayCam = pipeline:newCamera("overlay", {
        lerpingEnabled = false,
        canvas = lg.newCanvas(screenW, screenH),
        disableDrawPhase = true,
        layers = {16},  -- HUD only by default (mode 1)
    })

    -- Mode state
    local mode = 1

    local function setMode(m: integer)
        mode = m
        primaryCam:setActive(m == 1)
        minimapCam:setActive(m == 1)
        leftCam:setActive(m == 2)
        rightCam:setActive(m == 2)
        -- Overlay always active; toggle layer 15 (split-overlay) for mode 2
        if m == 1 then
            overlayCam:setLayers({16})
        else
            overlayCam:setLayers({15, 16})
        end
    end

    ---------------------------------------------------------------------------
    -- World content
    ---------------------------------------------------------------------------

    -- Checkered floor (padded beyond world bounds to avoid black edges)
    floor.spawnCheckered(world, {
        worldWidth = WORLD_W + 512,
        worldHeight = WORLD_H + 512,
        tileSize = 200,
        layer = 1,
        offsetX = -256,
        offsetY = -256,
    })

    -- Spawn running sprites with random colors and positions
    local runnerSheet = SpriteSheet.fromFile("assets/running.png")
    for i = 1, SPRITE_COUNT do
        local x = random(100, WORLD_W - 100)
        local y = random(100, WORLD_H - 100)

        local hue = (i / SPRITE_COUNT) * 6
        local r, g, b: number, number, number
        if hue < 1 then r, g, b = 1, hue, 0
        elseif hue < 2 then r, g, b = 2 - hue, 1, 0
        elseif hue < 3 then r, g, b = 0, 1, hue - 2
        elseif hue < 4 then r, g, b = 0, 4 - hue, 1
        elseif hue < 5 then r, g, b = hue - 4, 0, 1
        else r, g, b = 1, 0, 6 - hue end

        local angle = random() * pi * 2
        local speed = 30 + random() * 60
        local scale = 1.6 + random() * 1.6

        world:spawn(
            Transform(x, y, 0, 2, 0, scale, scale),
            gfx.Sprite.fromSheet(runnerSheet, "run", {
                centered = true,
                startTime = random() * 2.0,
            }),
            gfx.Color(r, g, b, 1),
            Velocity(cos(angle) * speed, sin(angle) * speed)
        )
    end

    ---------------------------------------------------------------------------
    -- TV frame (GPU entities, world space, layer 3)
    ---------------------------------------------------------------------------

    local outerW <const> = TV_W + TV_BORDER * 2
    local tvCenterX <const> = TV_X + TV_W / 2
    local tvCenterY <const> = TV_Y + TV_H / 2

    -- Frame top
    world:spawn(
        Transform.new({ x = tvCenterX, y = TV_Y - TV_BORDER / 2, z = 1, layer = 3 }),
        gfx.Rectangle(outerW, TV_BORDER),
        gfx.Color(0.35, 0.2, 0.08, 1)
    )
    -- Frame bottom
    world:spawn(
        Transform.new({ x = tvCenterX, y = TV_Y + TV_H + TV_BORDER / 2, z = 1, layer = 3 }),
        gfx.Rectangle(outerW, TV_BORDER),
        gfx.Color(0.35, 0.2, 0.08, 1)
    )
    -- Frame left
    world:spawn(
        Transform.new({ x = TV_X - TV_BORDER / 2, y = tvCenterY, z = 1, layer = 3 }),
        gfx.Rectangle(TV_BORDER, TV_H),
        gfx.Color(0.35, 0.2, 0.08, 1)
    )
    -- Frame right
    world:spawn(
        Transform.new({ x = TV_X + TV_W + TV_BORDER / 2, y = tvCenterY, z = 1, layer = 3 }),
        gfx.Rectangle(TV_BORDER, TV_H),
        gfx.Color(0.35, 0.2, 0.08, 1)
    )
    -- Inner shadow outline
    world:spawn(
        Transform.new({ x = tvCenterX, y = tvCenterY, z = 2, layer = 3 }),
        gfx.Rectangle(TV_W + 2, TV_H + 2, 2),
        gfx.Color(0.25, 0.14, 0.05, 1)
    )
    -- Label above TV
    world:spawn(
        Transform.new({ x = tvCenterX, y = TV_Y - TV_BORDER - 4, z = 3, layer = 3 }),
        gfx.Text(FONT, "IN-GAME VIEW"),
        gfx.Color(1, 1, 1, 0.8)
    )

    ---------------------------------------------------------------------------
    -- HUD entities (GPU, virtual space, layer 16)
    ---------------------------------------------------------------------------

    world:spawn(
        Transform.new({ x = virtualWidth / 2, y = VIRTUAL_HEIGHT - 8, layer = 16 }),
        gfx.Text(FONT, "[TAB] CYCLE CAMERAS", 0.8),
        gfx.Color(1, 1, 1, 0.7)
    )

    ---------------------------------------------------------------------------
    -- Split-screen overlay entities (GPU, virtual space, layer 15)
    ---------------------------------------------------------------------------

    -- Divider line (center of screen, full height)
    local dividerVirtualW = DIVIDER_WIDTH / pixelScale
    world:spawn(
        Transform.new({ x = virtualWidth / 2, y = VIRTUAL_HEIGHT / 2, layer = 15 }),
        gfx.Rectangle(dividerVirtualW, VIRTUAL_HEIGHT),
        gfx.Color(0.2, 0.2, 0.2, 1)
    )

    -- Control labels
    world:spawn(
        Transform.new({ x = 40, y = VIRTUAL_HEIGHT - 6, layer = 15 }),
        gfx.Text(FONT, "WASD + Q/E"),
        gfx.Color(1, 1, 1, 0.5)
    )
    world:spawn(
        Transform.new({ x = virtualWidth - 45, y = VIRTUAL_HEIGHT - 6, layer = 15 }),
        gfx.Text(FONT, "ARROWS + -/="),
        gfx.Color(1, 1, 1, 0.5)
    )

    ---------------------------------------------------------------------------
    -- Systems
    ---------------------------------------------------------------------------

    -- Movement query
    local moveQuery = world:query({
        name = "Movers",
        include = {Transform, Velocity},
    })

    -- Wander system: sprites bounce off world edges
    world:addSystem({
        name = "Wander",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            for archetype, len in moveQuery:iter() do
                local transforms = archetype:getMut(Transform)
                local velocities = archetype:getMut(Velocity)
                for i = 1, len do
                    local t = transforms[i]
                    local v = velocities[i]
                    t.x = t.x + v.vx * dt
                    t.y = t.y + v.vy * dt
                    if t.x < 0 then t.x = 0; v.vx = -v.vx end
                    if t.x > WORLD_W then t.x = WORLD_W; v.vx = -v.vx end
                    if t.y < 0 then t.y = 0; v.vy = -v.vy end
                    if t.y > WORLD_H then t.y = WORLD_H; v.vy = -v.vy end
                end
            end
        end,
    })

    -- Camera controls: mode-dependent
    world:addSystem({
        name = "CameraControls",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            -- TAB cycles mode
            if input.isKeyReleased("tab") then
                setMode(mode % 2 + 1)
            end

            if mode == 1 then
                -- WASD + zoom on primary camera
                if input.isKeyDown("w") then primaryCam:nudge(0, -CAMERA_SPEED * dt) end
                if input.isKeyDown("a") then primaryCam:nudge(-CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("s") then primaryCam:nudge(0, CAMERA_SPEED * dt) end
                if input.isKeyDown("d") then primaryCam:nudge(CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("=") or input.isKeyDown("+") then
                    primaryCam:setZoom(math.min(primaryCam:getZoom() * 1.03, 10))
                elseif input.isKeyDown("-") then
                    primaryCam:setZoom(primaryCam:getZoom() * 0.97)
                end
            else
                -- Left camera: WASD + Q/E zoom
                if input.isKeyDown("w") then leftCam:nudge(0, -CAMERA_SPEED * dt) end
                if input.isKeyDown("a") then leftCam:nudge(-CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("s") then leftCam:nudge(0, CAMERA_SPEED * dt) end
                if input.isKeyDown("d") then leftCam:nudge(CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("e") then
                    leftCam:setZoom(math.min(leftCam:getZoom() * 1.03, 10))
                elseif input.isKeyDown("q") then
                    leftCam:setZoom(leftCam:getZoom() * 0.97)
                end

                -- Right camera: arrows + -/= zoom
                if input.isKeyDown("up") then rightCam:nudge(0, -CAMERA_SPEED * dt) end
                if input.isKeyDown("left") then rightCam:nudge(-CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("down") then rightCam:nudge(0, CAMERA_SPEED * dt) end
                if input.isKeyDown("right") then rightCam:nudge(CAMERA_SPEED * dt, 0) end
                if input.isKeyDown("=") or input.isKeyDown("+") then
                    rightCam:setZoom(math.min(rightCam:getZoom() * 1.03, 10))
                elseif input.isKeyDown("-") then
                    rightCam:setZoom(rightCam:getZoom() * 0.97)
                end
            end

            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
            end
        end
    })

    -- TV screen: draw minimap canvas in world space (CPU draw, canvas changes every frame)
    world:addSystem({
        name = "TVScreen",
        phase = tecs.phases.Draw,
        run = function()
            local canvas = minimapCam:getCanvas()
            if not canvas then return end
            pipeline:worldShader():at(3, 0):unlit():attach()
            lg.setColor(1, 1, 1, 1)
            lg.draw(canvas, TV_X, TV_Y, 0, TV_W / MINIMAP_W, TV_H / MINIMAP_H)
            pipeline:detachWorldShader()
        end
    })

    -- Overlay blit (composites overlay camera's texture onto screen)
    world:addSystem({
        name = "OverlayBlit",
        phase = tecs.phases.PostRender,
        run = function()
            local canvas = overlayCam:getCanvas()
            if not canvas then return end
            lg.setBlendMode("alpha", "premultiplied")
            lg.setColor(1, 1, 1, 1)
            lg.draw(canvas, 0, 0)
            lg.setBlendMode("alpha")
        end
    })

    -- Minimap overlay (CPU draw, dynamic viewport indicator)
    local mx = screenW - MINIMAP_W - MINIMAP_MARGIN
    local my = MINIMAP_MARGIN

    world:addSystem({
        name = "MinimapOverlay",
        phase = tecs.phases.PostRender,
        run = function()
            if mode ~= 1 then return end

            local canvas = minimapCam:getCanvas()
            if not canvas then return end

            lg.setColor(1, 1, 1, 1)
            lg.draw(canvas, mx, my)

            -- Viewport indicator
            local cx, cy = primaryCam:getPosition()
            local vw, vh = primaryCam:getVisibleDimensions()
            local x1 = mx + (cx - vw / 2) / WORLD_W * MINIMAP_W
            local y1 = my + (cy - vh / 2) / WORLD_H * MINIMAP_H
            local w = vw / WORLD_W * MINIMAP_W
            local h = vh / WORLD_H * MINIMAP_H
            lg.setScissor(mx, my, MINIMAP_W, MINIMAP_H)
            lg.setColor(1, 1, 1, 0.9)
            lg.setLineWidth(1)
            lg.rectangle("line", x1, y1, w, h)
            lg.setScissor()
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    game = multiCamPlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lerpingEnabled = true,
        lerpSpeed = 8,
        cameraPosition = {WORLD_W / 2, WORLD_H / 2},
        lightingMode = "none",
        layers = {
            [1] = { name = "ground" },
            [2] = { name = "sprites" },
            [3] = { name = "tv" },
            [15] = { name = "split-overlay", space = "virtual" },
            [16] = { name = "hud", space = "virtual" },
        },
    },
})
