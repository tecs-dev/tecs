local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local render <const> = require("tecs_render")
local stats <const> = tecs2d.stats

local lg <const> = love.graphics

-- Force enable LuaJIT if available
tecs.enableJit()

-- Configuration
local WORLD_SIZE <const> = 5000
local RECT_COUNT <const> = 100000  -- Full count
local BATCH_SIZE <const> = 500     -- Spawn entities in batches to avoid memory issues
local UNLIT_CHANCE <const> = 0.1
local CAMERA_SPEED <const> = 500
local NORMAL_ADD <const> = 10000
local BULK_ADD <const> = 20000

-- Components
local record Rectangle is tecs.Component
    x: number
    y: number
    width: number
    height: number
    r: number
    g: number
    b: number
    unlit: boolean
end

-- Enable FFI storage for Rectangle component
tecs.newFFIComponent({
    name = "Rectangle",
    container = Rectangle,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"width", "float"},
        {"height", "float"},
        {"r", "float"},
        {"g", "float"},
        {"b", "float"},
        {"unlit", "bool"}
    },
    recycle = true
})

local record ShowcaseState
    camera: render.Camera
    pipeline: render.Pipeline
    cameraX: number
    cameraY: number
    mouseWorldX: number
    mouseWorldY: number
    scaleModeIndex: integer
    scaleModes: {string}
    lightingEnabled: boolean
    lerpingEnabled: boolean
    fullscreen: boolean
    entityCount: integer
    groundTexture: love.graphics.Image
    groundQuad: love.graphics.Quad
    spawnedCount: integer -- Track how many entities we've spawned so far
    spawning: boolean -- Whether we're still spawning initial entities
end

-- Pre-defined draw functions to avoid allocation
local function drawRectangle(rect: Rectangle)
    local x, y, w, h, r, g, b = rect.x, rect.y, rect.width, rect.height, rect.r, rect.g, rect.b
    local oldr, oldg, oldb, oldaa = lg.getColor()
    lg.setColor(r, g, b)
    lg.rectangle("fill", x, y, w, h)
    lg.setColor(oldr, oldg, oldb, oldaa)
end

local function createCheckerboardTexture(tileSize: number): love.graphics.Image
    local imageData = love.image.newImageData(tileSize * 2, tileSize * 2)
    for px = 0, tileSize * 2 - 1 do
        for py = 0, tileSize * 2 - 1 do
            local tileX = math.floor(px / tileSize)
            local tileY = math.floor(py / tileSize)
            local shade = ((tileX + tileY) % 2 == 0) and 0.2 or 0.3
            imageData:setPixel(px, py, 0.1, shade, 0.05, 1)
        end
    end
    local texture = lg.newImage(imageData) as love.graphics.Texture
    texture:setWrap("repeat", "repeat")
    texture:setFilter("nearest", "nearest")
    return texture as love.graphics.Image
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<ShowcaseState>

-- Plugin to set up the showcase
local function showcasePlugin(world: tecs.World)
    -- Create camera with high oversample for smooth zoom and lerping enabled
    local camera = render.newCamera({
        minWidth = 320,
        maxWidth = 640,
        height = 180,
        oversample = 3,
        lerpingEnabled = true,
        lerpSpeed = 8.0
    })

    -- Create render pipeline (automatically registers with world)
    local pipeline = render.newPipeline({
        world = world,
        camera = camera
    })

    -- Add stats plugin for debug info (F1 to toggle)
    world:addPlugin(stats.newStatsPlugin())

    -- Name our layers
    pipeline:nameLayer(1, "ground")
    pipeline:nameLayer(2, "entities")
    pipeline:nameLayer(3, "effects")
    pipeline:nameLayer(4, "hud")

    -- Set dim ambient light
    pipeline:setAmbientLight(0.1, 0.12, 0.15)

    -- Create checkerboard ground texture
    local tileSize = 50
    local groundTexture = createCheckerboardTexture(tileSize)
    local groundQuad = lg.newQuad(0, 0, WORLD_SIZE * 2, WORLD_SIZE * 2, tileSize * 2, tileSize * 2)

    -- Store state
    local state: ShowcaseState = {
        camera = camera,
        pipeline = pipeline,
        cameraX = WORLD_SIZE / 2,
        cameraY = WORLD_SIZE / 2,
        mouseWorldX = 0,
        mouseWorldY = 0,
        scaleModeIndex = 1,
        scaleModes = {"pixel", "aspect", "stretch", "none"},
        lightingEnabled = true,
        lerpingEnabled = true,
        fullscreen = false,
        entityCount = 0, -- Start with 0, will increment as we spawn
        groundTexture = groundTexture,
        groundQuad = groundQuad,
        spawnedCount = 0,
        spawning = true
    }

    camera:setPosition(state.cameraX, state.cameraY)
    world.resources[STATE_KEY] = state

    -- Batched spawning system to avoid memory overflow
    world:addSystem({
        name = "BatchedSpawning",
        phase = tecs.phases.Update,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s.spawning then
                return
            end

            local remainingToSpawn = RECT_COUNT - s.spawnedCount
            if remainingToSpawn <= 0 then
                s.spawning = false
                print(string.format("[DEBUG] Finished spawning all %d entities at %.0f FPS",
                    RECT_COUNT, love.timer.getFPS()))
                return
            end

            local batchSize = math.min(BATCH_SIZE, remainingToSpawn)
            -- Only print spawning status on first and last batch
            if s.spawnedCount == 0 then
                print(string.format("[DEBUG] Starting to spawn %d entities in batches of %d",
                    RECT_COUNT, BATCH_SIZE))
            end

            for _ = 1, batchSize do
                local r = math.random() * 0.5 + 0.5
                local g = math.random() * 0.5 + 0.5
                local b = math.random() * 0.5 + 0.5
                world:spawn(
                    Rectangle(
                        math.random(0, WORLD_SIZE),
                        math.random(0, WORLD_SIZE),
                        math.random(20, 100),
                        math.random(20, 100),
                        r,
                        g,
                        b,
                        math.random() < UNLIT_CHANCE
                    )
                )
                s.spawnedCount = s.spawnedCount + 1
                s.entityCount = s.entityCount + 1
            end
        end
    })

    -- Query for rectangles
    local rectangleQuery = world:query({
        include = {Rectangle}
    })

    -- Camera movement system
    world:addSystem({
        name = "CameraMovement",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local input = tecs2d.input
            local s = world.resources[STATE_KEY]

            -- Camera movement with WASD keys
            local dx, dy = 0.0, 0.0
            if input.isKeyDown("a") then dx = -1 end
            if input.isKeyDown("d") then dx = 1 end
            if input.isKeyDown("w") then dy = -1 end
            if input.isKeyDown("s") then dy = 1 end

            s.cameraX = s.cameraX + dx * CAMERA_SPEED * dt
            s.cameraY = s.cameraY + dy * CAMERA_SPEED * dt

            -- Clamp camera to world bounds
            s.cameraX = math.max(0, math.min(WORLD_SIZE, s.cameraX))
            s.cameraY = math.max(0, math.min(WORLD_SIZE, s.cameraY))

            s.camera:setPosition(s.cameraX, s.cameraY)

            -- Update mouse world coordinates
            local mx, my = love.mouse.getPosition()
            local wx, wy = s.camera:toWorld(mx, my)
            s.mouseWorldX = wx
            s.mouseWorldY = wy
        end
    })

    -- Input handling system
    world:addSystem({
        name = "InputHandler",
        phase = tecs.phases.Update,
        run = function()
            local input = tecs2d.input
            local s = world.resources[STATE_KEY]

            -- Handle mouse wheel zoom
            local wheelY = input.mouseWheelMoved[2]
            if wheelY ~= 0 then
                local currentZoom = s.camera:getZoom()
                if wheelY > 0 then
                    s.camera:setZoom(math.min(currentZoom * 1.33, 3))
                else
                    s.camera:setZoom(math.max(currentZoom / 1.33, 0.5))
                end
            end

            if input.isKeyDown("escape") then
                tecs2d.quit(0)
            elseif input.isKeyReleased("m") then
                -- Cycle scale modes by updating the existing camera
                s.scaleModeIndex = (s.scaleModeIndex % #s.scaleModes) + 1
                -- Note: scaleMode is managed by the camera internally
                -- Refresh the camera to apply the new scale mode
                s.camera:setScreenSize(love.graphics.getWidth(), love.graphics.getHeight())
            elseif input.isKeyReleased("l") then
                -- Toggle lighting
                s.lightingEnabled = not s.lightingEnabled
                if s.lightingEnabled then
                    s.pipeline:enableLighting()
                else
                    s.pipeline:disableLighting()
                end
            elseif input.isKeyReleased("f") then
                -- Toggle fullscreen
                s.fullscreen = not s.fullscreen
                love.window.setFullscreen(s.fullscreen)
            elseif input.isKeyReleased("c") then
                -- Toggle camera lerping
                s.lerpingEnabled = not s.lerpingEnabled
                s.camera:setLerpingEnabled(s.lerpingEnabled)
            elseif input.isKeyPressed("1") then
                local visible = s.pipeline:isLayerVisible("ground")
                s.pipeline:setLayerVisibility("ground", not visible)
            elseif input.isKeyReleased("2") then
                local visible = s.pipeline:isLayerVisible("entities")
                s.pipeline:setLayerVisibility("entities", not visible)
            elseif input.isKeyReleased("3") then
                local visible = s.pipeline:isLayerVisible("effects")
                s.pipeline:setLayerVisibility("effects", not visible)
            elseif input.isKeyReleased("4") then
                local visible = s.pipeline:isLayerVisible("hud")
                s.pipeline:setLayerVisibility("hud", not visible)
            elseif input.isKeyDown("q") then
                -- Darker ambient
                local r, g, b = s.pipeline:getAmbientLight()
                s.pipeline:setAmbientLight(math.max(0, r - 0.02), math.max(0, g - 0.02), math.max(0, b - 0.02))
            elseif input.isKeyDown("e") then
                -- Brighter ambient
                local r, g, b = s.pipeline:getAmbientLight()
                s.pipeline:setAmbientLight(math.min(1, r + 0.02), math.min(1, g + 0.02), math.min(1, b + 0.02))
            elseif input.isKeyDown("i") then
                local addCount = input.isKeyDown("lshift") and BULK_ADD or NORMAL_ADD
                for _ = 1, addCount do
                    local r = math.random() * 0.5 + 0.5
                    local g = math.random() * 0.5 + 0.5
                    local b = math.random() * 0.5 + 0.5
                    world:spawn(
                        Rectangle(
                            math.random(0, WORLD_SIZE),
                            math.random(0, WORLD_SIZE),
                            math.random(20, 100),
                            math.random(20, 100),
                            r,
                            g,
                            b,
                            math.random() < UNLIT_CHANCE
                        )
                    )
                    s.entityCount = s.entityCount + 1
                end
            elseif input.isKeyDown("o") then
                -- Remove last entities from archetypes (simple and efficient)
                local toRemove = 1000
                local removed = 0

                -- Remove from the end of each archetype until we've removed enough
                for _, len, entities in rectangleQuery() do
                    if removed >= toRemove then
                        break
                    end

                    -- Remove from the end of this archetype
                    local removeFromThis = math.min(len, toRemove - removed)
                    for i = len, len - removeFromThis + 1, -1 do
                        world:despawn(entities[i])
                        removed = removed + 1
                        s.entityCount = s.entityCount - 1
                    end
                end
            end
        end
    })

    -- Render system
    world:addSystem({
        name = "RenderShowcase",
        phase = tecs.phases.Render,
        run = function()
            local s = world.resources[STATE_KEY]
            local p = s.pipeline

            -- Draw ground with efficient texture wrapping
            local x1, y1, x2, y2 = s.camera:getVisibleCorners()
            p:draw("ground", x1, y1, x2 - x1, y2 - y1, function()
                s.groundQuad:setViewport(x1, y1, x2 - x1, y2 - y1)
                love.graphics.draw(s.groundTexture as love.graphics.Texture, s.groundQuad, x1, y1)
            end)

            -- Draw rectangle entities with frustum culling and batch rendering for performance
            local entityCount = 0
            local renderedCount = 0
            local archetypeCount = 0
            local ex1, ey1, ex2, ey2 = s.camera:getVisibleCorners()
            -- Add some padding to avoid popping at edges
            local padding = 100
            ex1, ey1 = ex1 - padding, ey1 - padding
            ex2, ey2 = ex2 + padding, ey2 + padding

            -- Use a single draw call for all entities to maximize performance
            p:draw("entities", ex1, ey1, ex2 - ex1, ey2 - ey1, function()
                for archetype, len in rectangleQuery() do
                    archetypeCount = archetypeCount + 1
                    entityCount = entityCount + len
                    local rects = archetype[Rectangle]
                    for row = 1, len do
                        local rect = rects[row]
                        -- Frustum culling: only render if entity is visible on screen
                        if rect.x + rect.width >= ex1 and rect.x <= ex2 and
                           rect.y + rect.height >= ey1 and rect.y <= ey2 then
                            drawRectangle(rect)
                            renderedCount = renderedCount + 1
                        end
                    end
                end
            end)

            -- Update actual entity count (might differ from spawn count during spawning)
            -- Only update if spawning is complete to avoid confusion
            if not s.spawning then
                s.entityCount = entityCount
            end

            -- Debug output every 60 frames (1 second at 60fps) - only if we have entities
            if entityCount > 0 and love.timer.getTime() % 1 < 0.016 then
                print(string.format("[RENDER] Total: %d entities, Rendered: %d (%.1f%%), FPS: %.0f",
                    entityCount, renderedCount, renderedCount / math.max(1, entityCount) * 100,
                    love.timer.getFPS()))
            end

            -- Mouse light
            p:drawLight("entities", s.mouseWorldX - 150, s.mouseWorldY - 150, 300, 300, function()
                lg.setColor(1, 1, 1, 1)
                lg.circle("fill", s.mouseWorldX, s.mouseWorldY, 100)
                -- Outer glow with gradient
                lg.setColor(1, 0.95, 0.8, 0.5)
                lg.circle("fill", s.mouseWorldX, s.mouseWorldY, 150)
            end)

            -- Draw HUD (unlit, absolute positioning)
            p:drawAbsolute(function()
                local screenWidth = lg.getWidth()
                local screenHeight = lg.getHeight()

                -- Modal status bar at bottom
                local barHeight = 50
                local barY = screenHeight - barHeight

                -- Draw bar background (darkish matte blue)
                lg.setColor(0.15, 0.2, 0.35, 0.95)
                lg.rectangle("fill", 0, barY, screenWidth, barHeight)

                -- Bar border
                lg.setColor(0.2, 0.25, 0.4, 1)
                lg.rectangle("line", 0, barY, screenWidth, barHeight)

                -- HUD text
                local hudText = "Smooth (C)am | (L)ighting | (F)ullscreen | (M)ode"

                -- Draw HUD text centered
                lg.setColor(0.9, 0.9, 0.9, 1)
                local textWidth = lg.getFont():getWidth(hudText)
                local textX = (screenWidth - textWidth) / 2
                local textY = barY + (barHeight - 16) / 2
                lg.print(hudText, textX, textY)

                -- Additional controls hint (small text at very bottom)
                lg.setColor(0.7, 0.7, 0.7, 1)
                local currentMode = s.scaleModes[s.scaleModeIndex]:upper()
                local helpText = "WASD: Move | Mouse wheel: Zoom | Q/E: Ambient | I/O: Add/Remove | ESC: Quit | Mode: " .. currentMode
                lg.print(helpText, 30, barY - 24)
            end)
        end
    })
end

-- Override love.run to use tecs2d
function love.run(): function(): string | number
    return tecs2d.run(1 / 60, function(world: tecs.World)
        world:addPlugin(showcasePlugin)
    end)
end