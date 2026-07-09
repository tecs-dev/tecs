--[[
    Lighting & Shadows Demo

    Stress test for the GPU lighting system with deferred rendering and shadow casting.
    Features a large map with many balls (circles) lit by multiple light sources.
    The mouse acts as a movable light source that casts shadows.

    Controls:
    - WASD: Move camera
    - +/-: Zoom in/out, 0: Reset zoom
    - UP/DOWN: Add/remove balls
    - Scroll wheel: Cycle light cookie (gobo)
    - R: Rotate cookie
    - ;/': Adjust light intensity
    - [/]: Adjust light radius
    - ,/.: Adjust light height
    - L: Toggle lighting
    - B: Toggle bloom
    - Q/E: Adjust ambient light
    - F: Toggle fullscreen
    - ESC: Quit
]]

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")
local floor <const> = require("floor")

local Text <const> = gfx.Text
local Sprite <const> = gfx.Sprite
local FONT_PATH <const> = "assets/press-start-2p.fnt"
local RUNNER_PATH <const> = "assets/running.png"
local HUD_LAYER <const> = 16

-- Configuration
local INITIAL_BALLS <const> = 2000 as integer
local WORLD_SIZE <const> = 8000
local CAMERA_SPEED <const> = 1200
local MAX_FRAME_CHANGES <const> = 500
local BALL_ADD_STEP <const> = 1000


local record LightingState
    pipeline: gfx.Pipeline
    lightingEnabled: boolean
    lerpingEnabled: boolean
    fullscreen: boolean
    targetBallCount: integer
    currentBallCount: integer
    mouseLightEntity: integer
    mouseLightIntensity: number
    mouseLightRadius: number
    mouseLightHeight: number
    mouseWorldX: number
    mouseWorldY: number
    pixelMode: boolean
    lightCount: integer
    circlesText: integer
    zoomText: integer
    cookieIndex: integer
    cookieIds: {integer}
    cookieNames: {string}
    cookieRotation: number
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<LightingState>

-- Color palette for lights
local LIGHT_COLORS <const>: {{number, number, number}} = {
    {1.0, 0.3, 0.3},  -- Red
    {1.0, 0.6, 0.2},  -- Orange
    {1.0, 1.0, 0.3},  -- Yellow
    {0.3, 1.0, 0.4},  -- Green
    {0.3, 0.8, 1.0},  -- Cyan
    {0.4, 0.4, 1.0},  -- Blue
    {0.8, 0.3, 1.0},  -- Purple
    {1.0, 0.4, 0.8},  -- Pink
    {1.0, 0.9, 0.8},  -- Warm white
}

-------------------------------------------------------------------------------
-- Procedural cookie texture generators
-------------------------------------------------------------------------------

local spriteSheetModule <const> = gfx.SpriteSheet

--- Generate a window blinds cookie: horizontal stripes with soft edges.
local function generateBlindsCookie(size: integer, slats: integer): love.graphics.Image
    local data = love.image.newImageData(size, size)
    local slatHeight = size / slats
    for y = 0, size - 1 do
        local within = (y % slatHeight) / slatHeight
        -- Smooth open/closed bands: 0..0.4 = open, 0.4..0.6 = edge, 0.6..1 = closed
        local a: number
        if within < 0.35 then
            a = 0.0
        elseif within < 0.5 then
            a = (within - 0.35) / 0.15
        else
            a = 1.0
        end
        for x = 0, size - 1 do
            data:setPixel(x, y, 1, 1, 1, a)
        end
    end
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

--- Generate a crosshair/grid cookie: concentric rings + cross.
local function generateGridCookie(size: integer): love.graphics.Image
    local data = love.image.newImageData(size, size)
    local cx, cy = size * 0.5, size * 0.5
    local maxR = size * 0.5
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local dx = x - cx + 0.5
            local dy = y - cy + 0.5
            local dist = math.sqrt(dx * dx + dy * dy) / maxR

            -- Concentric rings
            local ringFreq = dist * 4.0
            local ring = math.abs(math.sin(ringFreq * math.pi))
            ring = ring > 0.7 and 1.0 or ring / 0.7

            -- Cross lines (thicker toward center)
            local crossW = 0.03
            local onCross = (math.abs(dx / maxR) < crossW or math.abs(dy / maxR) < crossW) and 1.0 or 0.0

            -- Combine: ring pattern masked by radial falloff
            local a = math.max(ring * 0.8, onCross)
            -- Fade at edges
            if dist > 0.85 then
                a = a * math.max(0, 1.0 - (dist - 0.85) / 0.15)
            end
            data:setPixel(x, y, 1, 1, 1, a)
        end
    end
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

--- Generate a stained glass cookie: colored wedges like a cathedral window.
local function generateStainedGlassCookie(size: integer): love.graphics.Image
    local data = love.image.newImageData(size, size)
    local margin = math.floor(size * 0.1)
    local frameW = math.floor(size * 0.04)
    local mullionW = math.floor(size * 0.05)
    local halfMullion = mullionW * 0.5
    local midX, midY = size * 0.5, size * 0.5
    -- 4 panes: top-left, top-right, bottom-left, bottom-right
    local colors <const>: {{number, number, number}} = {
        {0.2, 0.5, 0.9},  -- Blue (top-left)
        {0.9, 0.7, 0.1},  -- Amber (top-right)
        {0.2, 0.8, 0.3},  -- Green (bottom-left)
        {0.9, 0.2, 0.2},  -- Red (bottom-right)
    }
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            -- Outside the window frame: transparent (no light)
            if x < margin or x >= size - margin or y < margin or y >= size - margin then
                data:setPixel(x, y, 0.05, 0.05, 0.05, 0.0)
            -- Mullions (cross bars between panes): dark lead
            elseif math.abs(x - midX) < halfMullion or math.abs(y - midY) < halfMullion then
                data:setPixel(x, y, 0.1, 0.1, 0.1, 0.15)
            -- Frame border (inner edge): dark lead
            elseif x < margin + frameW or x >= size - margin - frameW
                or y < margin + frameW or y >= size - margin - frameW then
                data:setPixel(x, y, 0.1, 0.1, 0.1, 0.15)
            else
                -- Determine which pane (quadrant)
                local pane: integer
                if x < midX then
                    pane = y < midY and 1 or 3
                else
                    pane = y < midY and 2 or 4
                end
                local col = colors[pane]
                data:setPixel(x, y, col[1], col[2], col[3], 0.9)
            end
        end
    end
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

local function lightingPlugin(world: tecs.World)
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Add plugins
    world:addPlugin(stats.newStatsPlugin())
    world:addPlugin(mcp.new())

    local initialIntensity = 3.0
    local initialRadius = 400
    local initialHeight = 0.3

    local Transform <const> = tecs.builtins.Transform
    local goldColor <const> = gfx.Color(0.95, 0.65, 0.25, 1)

    -- HUD text entities (screen-space layer, renders at native resolution)
    local ChildOf <const> = tecs.builtins.ChildOf
    local RelativeTransform <const> = tecs.builtins.RelativeTransform
    local Anchor <const> = ui.Anchor
    local hudScale <const> = 0.6
    local hudLineH <const> = 32
    local hudLines <const> = 6

    -- Parent anchored 20px from bottom-left corner
    local hudRoot: integer = world:spawn(
        Transform(0, 0, 0, HUD_LAYER),
        Anchor(0, 1, 20, -(hudLines * hudLineH + 20))
    )
    world:commit()

    -- Children stack downward from parent via RelativeTransform + ChildOf
    world:spawn(
        Transform(0, 0, 0, HUD_LAYER), RelativeTransform(0, 0),
        ChildOf(hudRoot) as tecs.Component,
        Text(FONT_PATH, "WASD: Move | +/-/0: Zoom | Click: Spawn light at cursor", hudScale),
        goldColor, gfx.Pivot(0, 0)
    )
    world:spawn(
        Transform(0, 0, 0, HUD_LAYER),
        ChildOf(hudRoot) as tecs.Component, RelativeTransform(0, hudLineH),
        Text(FONT_PATH, "Scroll: Cookie | R: Rotate | ,/.: Height | [/]: Radius | ;/': Intensity", hudScale),
        goldColor, gfx.Pivot(0, 0)
    )
    world:spawn(
        Transform(0, 0, 0, HUD_LAYER),
        ChildOf(hudRoot) as tecs.Component, RelativeTransform(0, hudLineH * 2),
        Text(FONT_PATH, "UP/DOWN: Balls | RIGHT/LEFT: Lights | L: Lighting | B: Bloom", hudScale),
        goldColor, gfx.Pivot(0, 0)
    )
    world:spawn(
        Transform(0, 0, 0, HUD_LAYER),
        ChildOf(hudRoot) as tecs.Component, RelativeTransform(0, hudLineH * 3),
        Text(FONT_PATH, "P: Pixel | Q/E: Ambient | F: Fullscreen | ESC: Quit", hudScale),
        goldColor, gfx.Pivot(0, 0)
    )
    -- Dynamic text
    local circlesText = world:spawn(
        Transform(0, 0, 0, HUD_LAYER),
        ChildOf(hudRoot) as tecs.Component, RelativeTransform(0, hudLineH * 4),
        Text(FONT_PATH, "Circles: 0 | Lights: 1 | Pixel: off", hudScale),
        goldColor, gfx.Pivot(0, 0)
    )
    local zoomText = world:spawn(
        Transform.new({layer = HUD_LAYER}),
        ChildOf(hudRoot) as tecs.Component,
        RelativeTransform(0, (hudLineH * 5)),
        Text(FONT_PATH, string.format("Zoom: 0.50x | Cursor Light: I=%.1f R=%.0f H=%.2f", initialIntensity, initialRadius, initialHeight), hudScale),
        goldColor, gfx.Pivot(0, 0)
    )

    local state: LightingState = {
        pipeline = pipeline,
        lightingEnabled = true,
        lerpingEnabled = true,
        fullscreen = false,
        targetBallCount = INITIAL_BALLS,
        currentBallCount = 0,
        mouseLightIntensity = initialIntensity,
        mouseLightRadius = initialRadius,
        mouseLightHeight = initialHeight,
        mouseWorldX = WORLD_SIZE / 2,
        mouseWorldY = WORLD_SIZE / 2,
        pixelMode = false,
        lightCount = 0,
        circlesText = circlesText,
        zoomText = zoomText,
    }

    world.resources[STATE_KEY] = state

    -- Create a checkered green floor pattern (extends 1024 beyond world bounds)
    floor.spawnCheckered(world, {
        worldWidth = WORLD_SIZE + 2048,
        worldHeight = WORLD_SIZE + 2048,
        tileSize = 400,
        layer = 1,
        offsetX = -1024,
        offsetY = -1024,
    })

    -- Spawn initial shapes
    -- 1/20 = rectangles, 19/20 = circles, all cast shadows
    local rectCount = math.floor(INITIAL_BALLS / 20) as integer
    local circleCount = INITIAL_BALLS - rectCount

    -- Shadow-casting rectangles (1/20 of total)
    world:batchSpawn(rectCount,
        {Transform as tecs.Component, gfx.Rectangle as tecs.Component, gfx.Color as tecs.Component, gfx.Occluder as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            for i = startRow, lastRow do
                arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 2))
                arch:set(i, gfx.Rectangle(16 + math.random() * 48, 16 + math.random() * 48))
                arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, 1))
                arch:set(i, gfx.Occluder())
            end
        end)

    -- Shadow-casting circles (19/20 of total)
    world:batchSpawn(circleCount,
        {Transform as tecs.Component, gfx.Circle as tecs.Component, gfx.Color as tecs.Component, gfx.Occluder as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            for i = startRow, lastRow do
                arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 2))
                arch:set(i, gfx.Circle(8 + math.random() * 24))
                arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, 1))
                arch:set(i, gfx.Occluder())
            end
        end)
    state.currentBallCount = INITIAL_BALLS

    -- Load running man sprite with auto-generated normal map
    local runnerSheet = spriteSheetModule.fromFile(RUNNER_PATH, { generateNormal = true })

    -- Spawn one running man sprite
    world:spawn(
        tecs.builtins.Transform(
            WORLD_SIZE / 2 - 20,
            WORLD_SIZE / 2 - 100,
            0,
            2,  -- Layer 2 = shapes
            0,  -- rotation
            3, 3
        ),
        Sprite.fromSheet(runnerSheet),
        gfx.Pivot(0.5, 1.0),  -- Bottom-center pivot
        gfx.DropShadow()  -- Drop shadow
    )

    -- Load light bulb sprite - fromTextureFile auto-loads material maps (_n, _e, _s)
    local bulbSheet = spriteSheetModule.fromTextureFile("assets/lightbulb.png")

    -- Spawn light bulbs at center of world with lights at the filament
    local BULB_COUNT <const> = 5
    local BULB_SCALE <const> = 4
    for i = 1, BULB_COUNT do
        local bx = WORLD_SIZE / 2 + (i - 3) * 200
        local by = WORLD_SIZE / 2

        -- Spawn the light bulb sprite
        world:spawn(
            tecs.builtins.Transform(bx, by, 0, 2, 0, BULB_SCALE, BULB_SCALE),
            Sprite.fromSheet(bulbSheet),
            gfx.Pivot(0.5, 0.5)
        )

        -- Warm light at the filament (glass part of bulb)
        world:spawn(
            tecs.builtins.Transform(bx, by - 20, 0, 1),
            gfx.Light.new({
                radius = 180,
                intensity = 1.0,
                height = 0.3,
                r = 1.0, g = 0.85, b = 0.5
            })
        )
    end

    -- Spawn random trees
    local TREE_COUNT <const> = 200
    local treeSheet = spriteSheetModule.fromTextureFile("assets/tree-branched.png")
    world:batchSpawn(TREE_COUNT,
        {Transform as tecs.Component, Sprite as tecs.Component, gfx.Pivot as tecs.Component, gfx.DropShadow as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            for i = startRow, lastRow do
                arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 2))
                arch:set(i, Sprite.fromSheet(treeSheet))
                arch:set(i, gfx.Pivot(0.5, 1.0))
                arch:set(i, gfx.DropShadow())
            end
        end)

    -- Register light cookies (gobos)
    local blindsImg = generateBlindsCookie(128, 8)
    local blindsSheet = spriteSheetModule.fromTexture(blindsImg as love.graphics.Texture)
    local blindsId = pipeline:registerCookie("blinds", blindsSheet)

    local gridImg = generateGridCookie(128)
    local gridSheet = spriteSheetModule.fromTexture(gridImg as love.graphics.Texture)
    local gridId = pipeline:registerCookie("grid", gridSheet)

    local glassImg = generateStainedGlassCookie(256)
    local glassSheet = spriteSheetModule.fromTexture(glassImg as love.graphics.Texture)
    local glassId = pipeline:registerCookie("stained_glass", glassSheet)

    local runnerId = pipeline:registerCookie("runner", runnerSheet, "run")

    -- Cookie selection: index 1 = none, 2-5 = registered cookies
    state.cookieIds = { 0, blindsId, gridId, glassId, runnerId }
    state.cookieNames = { "none", "blinds", "grid", "stained glass", "runner" }
    state.cookieIndex = 1
    state.cookieRotation = 0

    -- Create mouse light entity (follows mouse, warm white)
    local mouseLightId = world:spawn(
        tecs.builtins.Transform(WORLD_SIZE / 2, WORLD_SIZE / 2, 0, 3),
        gfx.Light.new({
            radius = initialRadius,
            intensity = initialIntensity,
            height = initialHeight,
            r = 1.0, g = 0.95, b = 0.85,
        })
    )
    state.mouseLightEntity = mouseLightId

    local circleQuery = world:query({ include = { gfx.Circle } })
    local rectQuery = world:query({ include = { gfx.Rectangle } })
    local lightQuery = world:query({ include = { gfx.Light } })

    -- Entity management system (add/remove balls based on target)
    world:addSystem({
        name = "BallManager",
        phase = tecs.phases.FixedUpdate,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local delta = s.targetBallCount - s.currentBallCount
            local changes = math.min(math.abs(delta), MAX_FRAME_CHANGES)

            if delta > 0 then
                -- Batch spawn shapes (1/20 rectangles, 19/20 circles, all cast shadows)
                local rectChanges = math.floor(changes / 20)
                local circleChanges = changes - rectChanges
                if rectChanges > 0 then
                    world:batchSpawn(rectChanges,
                        {Transform as tecs.Component, gfx.Rectangle as tecs.Component, gfx.Color as tecs.Component, gfx.Occluder as tecs.Component},
                        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
                            for i = startRow, lastRow do
                                arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 2))
                                arch:set(i, gfx.Rectangle(16 + math.random() * 48, 16 + math.random() * 48))
                                arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, 1))
                                arch:set(i, gfx.Occluder())
                            end
                        end)
                end
                if circleChanges > 0 then
                    world:batchSpawn(circleChanges,
                        {Transform as tecs.Component, gfx.Circle as tecs.Component, gfx.Color as tecs.Component, gfx.Occluder as tecs.Component},
                        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
                            for i = startRow, lastRow do
                                arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 2))
                                arch:set(i, gfx.Circle(8 + math.random() * 24))
                                arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, 1))
                                arch:set(i, gfx.Occluder())
                            end
                        end)
                end
                s.currentBallCount = s.currentBallCount + changes
            elseif delta < 0 then
                -- Despawn shapes (circles and rectangles)
                local toRemove: {integer} = {}
                for _, len, entities in circleQuery:iter() do
                    for row = 1, len do
                        toRemove[#toRemove + 1] = entities[row]
                        if #toRemove >= changes then break end
                    end
                    if #toRemove >= changes then break end
                end
                if #toRemove < changes then
                    for _, len, entities in rectQuery:iter() do
                        for row = 1, len do
                            toRemove[#toRemove + 1] = entities[row]
                            if #toRemove >= changes then break end
                        end
                        if #toRemove >= changes then break end
                    end
                end
                for _, eid in ipairs(toRemove) do world:despawn(eid) end
                s.currentBallCount = s.currentBallCount - #toRemove
            end
        end
    })

    local input = require("tecs2d.input")

    -- Mouse light tracking system (follows mouse position in world coords)
    world:addSystem({
        name = "MouseLightTracker",
        phase = tecs.phases.FixedUpdate,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s or not s.mouseLightEntity then return end

            -- Convert mouse screen position to world position
            local mx, my = input.mouseX, input.mouseY
            local wx, wy = s.pipeline:getCamera():toWorld(mx, my)
            s.mouseWorldX = wx
            s.mouseWorldY = wy

            -- Update the light entity's transform
            local transform = world:get(s.mouseLightEntity, tecs.builtins.Transform)
            if transform then
                transform.x = wx
                transform.y = wy
            end
        end
    })

    -- Input system
    world:addSystem({
        name = "Input",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end
            local p = s.pipeline
            local cam = p:getCamera()

            -- Camera panning with WASD
            if input.isKeyDown("d") then
                cam:nudge(CAMERA_SPEED * dt, 0)
            end
            if input.isKeyDown("a") then
                cam:nudge(-CAMERA_SPEED * dt, 0)
            end
            if input.isKeyDown("s") then
                cam:nudge(0, CAMERA_SPEED * dt)
            end
            if input.isKeyDown("w") then
                cam:nudge(0, -CAMERA_SPEED * dt)
            end

            -- Camera zoom with +/-, reset with 0
            if input.isKeyDown("=") or input.isKeyDown("+") then
                local currentZoom = cam:getZoom()
                cam:setZoom(math.min(currentZoom * 1.05, 10))
            elseif input.isKeyDown("-") then
                local currentZoom = cam:getZoom()
                cam:setZoom(math.max(currentZoom * 0.95, 0.01))
            elseif input.isKeyReleased("0") then
                cam:setZoom(1.0)
            end

            -- Add/remove balls with UP/DOWN
            if input.isKeyReleased("up") then
                local addCount = input.isKeyDown("lshift") and BALL_ADD_STEP * 5 or BALL_ADD_STEP
                s.targetBallCount = s.targetBallCount + addCount
            elseif input.isKeyReleased("down") then
                local removeCount = input.isKeyDown("lshift") and BALL_ADD_STEP * 5 or BALL_ADD_STEP
                s.targetBallCount = math.max(0, s.targetBallCount - removeCount)
            end

            -- Add/remove lights with RIGHT/LEFT
            if input.isKeyReleased("right") then
                local addCount = input.isKeyDown("lshift") and 1000 or 100
                world:batchSpawn(addCount,
                    {Transform as tecs.Component, gfx.Light as tecs.Component},
                    function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
                        for i = startRow, lastRow do
                            local col = LIGHT_COLORS[math.random(#LIGHT_COLORS)]
                            arch:set(i, Transform(math.random() * WORLD_SIZE, math.random() * WORLD_SIZE, 0, 3))
                            arch:set(i, gfx.Light(100 + math.random() * 400, 0.5 + math.random() * 3.0, 0.05 + math.random() * 0.9, col[1], col[2], col[3]))
                        end
                    end)
                s.lightCount = s.lightCount + addCount
            elseif input.isKeyReleased("left") then
                local removeCount = input.isKeyDown("lshift") and 1000 or 100
                local toRemove: {integer} = {}
                for _, len, entities in lightQuery:iter() do
                    for row = 1, len do
                        -- Don't despawn the mouse light
                        if entities[row] ~= s.mouseLightEntity then
                            toRemove[#toRemove + 1] = entities[row]
                            if #toRemove >= removeCount then break end
                        end
                    end
                    if #toRemove >= removeCount then break end
                end
                for _, eid in ipairs(toRemove) do world:despawn(eid) end
                s.lightCount = s.lightCount - #toRemove
            end

            -- Toggle controls
            if input.isKeyReleased("f") then
                s.fullscreen = not s.fullscreen
                love.window.setFullscreen(s.fullscreen, "desktop")
            elseif input.isKeyReleased("l") then
                if s.lightingEnabled then
                    p:disableLighting()
                    s.lightingEnabled = false
                else
                    p:enableLighting()
                    s.lightingEnabled = true
                end
            elseif input.isKeyReleased("b") then
                local bloom = p:getBloom()
                p:setBloom({ enabled = not bloom.enabled })
            elseif input.isKeyDown("q") then
                local r, g, b = p:getAmbientLight()
                p:setAmbientLight(math.max(0, r - 0.01), math.max(0, g - 0.01), math.max(0, b - 0.01))
            elseif input.isKeyDown("e") then
                local r, g, b = p:getAmbientLight()
                p:setAmbientLight(math.min(1, r + 0.01), math.min(1, g + 0.01), math.min(1, b + 0.01))
            end

            -- Mouse wheel: cycle cookie
            local _, wheelY = input.getMouseWheelMovement()
            if wheelY ~= 0 then
                local total = #s.cookieIds
                if wheelY > 0 then
                    s.cookieIndex = s.cookieIndex % total + 1
                else
                    s.cookieIndex = (s.cookieIndex - 2) % total + 1
                end
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.cookie = s.cookieIds[s.cookieIndex]
                    lightComp.cookieRotation = s.cookieRotation
                end
            end

            -- R: Rotate cookie
            if input.isKeyDown("r") then
                s.cookieRotation = s.cookieRotation + 1.5 * dt
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.cookieRotation = s.cookieRotation
                end
            end

            -- Click to spawn a light at mouse position (inherits active cookie)
            if input.isMouseReleased(1) then
                local col = LIGHT_COLORS[math.random(#LIGHT_COLORS)]
                world:spawn(
                    tecs.builtins.Transform(s.mouseWorldX, s.mouseWorldY, 0, 3),
                    gfx.Light.new({
                        radius = s.mouseLightRadius,
                        intensity = s.mouseLightIntensity,
                        height = s.mouseLightHeight,
                        r = col[1], g = col[2], b = col[3],
                        cookie = s.cookieIds[s.cookieIndex],
                        cookieRotation = s.cookieRotation,
                    })
                )
                s.lightCount = s.lightCount + 1
            end

            -- P: Toggle pixel mode
            if input.isKeyReleased("p") then
                s.pixelMode = not s.pixelMode
                p:setPixelMode(s.pixelMode)
            end

            -- , / . or mouse back/forward: Adjust light height
            if input.isKeyDown(",") or input.isMouseDown(5) then
                s.mouseLightHeight = math.max(0.01, s.mouseLightHeight - 0.02)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.height = s.mouseLightHeight
                end
            elseif input.isKeyDown(".") or input.isMouseDown(4) then
                s.mouseLightHeight = math.min(1.0, s.mouseLightHeight + 0.02)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.height = s.mouseLightHeight
                end
            end

            -- [ / ]: Adjust light radius
            if input.isKeyDown("[") then
                s.mouseLightRadius = math.max(50, s.mouseLightRadius - 5)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.radius = s.mouseLightRadius
                end
            elseif input.isKeyDown("]") then
                s.mouseLightRadius = math.min(2000, s.mouseLightRadius + 5)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.radius = s.mouseLightRadius
                end
            end

            -- ; / ': Adjust light intensity
            if input.isKeyDown(";") then
                s.mouseLightIntensity = math.max(0.1, s.mouseLightIntensity - 0.05)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.intensity = s.mouseLightIntensity
                end
            elseif input.isKeyDown("'") then
                s.mouseLightIntensity = math.min(10.0, s.mouseLightIntensity + 0.05)
                local lightComp = world:get(s.mouseLightEntity, gfx.Light)
                if lightComp then
                    lightComp.intensity = s.mouseLightIntensity
                end
            end
        end
    })

    -- HUD text update
    world:addSystem({
        name = "UpdateHUD",
        phase = tecs.phases.Update,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local circlesTextComp = world:get(s.circlesText, Text)
            if circlesTextComp then
                circlesTextComp:setText(string.format("Circles: %d | Lights: %d | Pixel: %s",
                    s.currentBallCount, s.lightCount + 1, s.pixelMode and "on" or "off"))
            end

            local zoomTextComp = world:get(s.zoomText, Text)
            if zoomTextComp then
                local zoom = s.pipeline:getCamera():getZoom()
                local cookieName = s.cookieNames[s.cookieIndex] or "none"
                zoomTextComp:setText(string.format("Zoom: %.2fx | Cookie: %s | I=%.1f R=%.0f H=%.2f",
                    zoom, cookieName, s.mouseLightIntensity, s.mouseLightRadius, s.mouseLightHeight))
            end
        end
    })

end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(lightingPlugin)
    end,
    render = {
        virtualHeight = 270,
        zoom = 1,
        cameraPosition = {WORLD_SIZE / 2, WORLD_SIZE / 2},
        ambientLight = {0.05, 0.06, 0.08},
        bloom = { enabled = true, intensity = 0.35, radius = 1.2, threshold = 0.0 },
        layers = {
            [1] = { name = "background" },
            [2] = { name = "balls" },
            [3] = { name = "lights" },
            [16] = { name = "hud", space = "screen" },
        },
    },
})
