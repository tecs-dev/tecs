--- Mesh Demo
--- Demonstrates GPU-instanced mesh rendering using the Mesh component and MeshDefinition.
--- Integrated with G-buffer pipeline for deferred lighting support.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")

local Transform <const> = tecs.builtins.Transform
local Mesh <const> = gfx.Mesh
local MeshDefinition <const> = gfx.MeshDefinition
local Color <const> = gfx.Color
local Light <const> = gfx.Light
local Text <const> = gfx.Text

local lg <const> = love.graphics

-- Configuration
local WORLD_WIDTH <const> = 1200
local WORLD_HEIGHT <const> = 900
local CAMERA_SPEED <const> = 400
local FONT_PATH <const> = "assets/press-start-2p.fnt"
local VIRTUAL_HEIGHT <const> = 180
local HUD_LAYER <const> = 4

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

local function createTriangleMesh(): love.graphics.Mesh
    local vertices = {
        { 0, -40, 0, 0, 1, 1, 1, 1 },    -- top
        { -35, 35, 0, 1, 1, 1, 1, 1 },   -- bottom-left
        { 35, 35, 1, 1, 1, 1, 1, 1 },    -- bottom-right
    }
    local format = {
        { name = "VertexPosition", format = "floatvec2", location = 0 },
        { name = "VertexTexCoord", format = "floatvec2", location = 1 },
        { name = "VertexColor", format = "floatvec4", location = 2 },
    }
    return lg.newMesh(format as {{number | string}}, vertices, "triangles", "static")
end

local function createDiamondMesh(): love.graphics.Mesh
    local size <const> = 30
    local vertices: {{number}} = {
        { 0, -size, 0, 0, 1, 1, 1, 1 },
        { -size, 0, 0, 0.5, 1, 1, 1, 1 },
        { 0, size, 0.5, 1, 1, 1, 1, 1 },
        { 0, -size, 0, 0, 1, 1, 1, 1 },
        { 0, size, 0.5, 1, 1, 1, 1, 1 },
        { size, 0, 1, 0.5, 1, 1, 1, 1 },
    }
    local format = {
        { name = "VertexPosition", format = "floatvec2", location = 0 },
        { name = "VertexTexCoord", format = "floatvec2", location = 1 },
        { name = "VertexColor", format = "floatvec4", location = 2 },
    }
    return lg.newMesh(format as {{number | string}}, vertices, "triangles", "static")
end

-------------------------------------------------------------------------------
-- Animation component
-------------------------------------------------------------------------------

local record Animated is tecs.Component
    baseY: number
    offset: number
    metamethod __call: function(self, baseY: number, offset: number): Animated
end

tecs.newComponent({
    name = "Animated",
    container = Animated,
    fields = {"baseY", "offset"},
    init = function(instance: Animated, baseY: number, offset: number)
        instance.baseY = baseY
        instance.offset = offset
    end
})

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local record DemoState
    pipeline: gfx.Pipeline
    mouseLightEntity: integer
    mouseWorldX: number
    mouseWorldY: number
    totalEntities: integer
    zoomTextEntity: integer
    -- Expanding world bounds for mesh spawning
    worldMinX: number
    worldMinY: number
    worldMaxX: number
    worldMaxY: number
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<DemoState>

-------------------------------------------------------------------------------
-- Game
-------------------------------------------------------------------------------

local function meshDemoPlugin(world: tecs.World)
    local input = require("tecs2d.input")

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Add plugins
    world:addPlugin(mcp.new())
    world:addPlugin(stats.newStatsPlugin())

    local goldColor <const> = Color(0.95, 0.65, 0.25, 1)

    -- HUD text (layer is unlit)
    world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 23, 0, HUD_LAYER),
        Text(FONT_PATH, "WASD: Move | -/=: Zoom | R: Reset | Space: +100 meshes", 0.15),
        goldColor, gfx.Pivot(0, 0)
    )
    local zoomTextEntity = world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 15, 0, HUD_LAYER),
        Text(FONT_PATH, "Meshes: 0 | Zoom: 0.80x", 0.15),
        goldColor, gfx.Pivot(0, 0)
    )

    -- State - start with a reasonable spawn area that expands
    local state: DemoState = {
        pipeline = pipeline,
        mouseWorldX = WORLD_WIDTH / 2,
        mouseWorldY = WORLD_HEIGHT / 2,
        totalEntities = 0,
        zoomTextEntity = zoomTextEntity,
        worldMinX = 0,
        worldMinY = 0,
        worldMaxX = WORLD_WIDTH,
        worldMaxY = WORLD_HEIGHT,
    }
    world.resources[STATE_KEY] = state


    -- Register mesh definitions
    MeshDefinition.new("triangle", createTriangleMesh(), 500)
    MeshDefinition.new("diamond", createDiamondMesh(), 500)

    -- Spawn grid of triangles
    local startTime = love.timer.getTime()
    local entityIdx = 0
    for row = 0, 4 do
        for col = 0, 4 do
            local x = 200 + col * 100
            local y = 200 + row * 100
            world:spawn(
                Transform(x, y, 0, 2),
                Mesh("triangle"),
                Color(0.5 + col / 10, 0.5 + row / 10, 0.8, 1),
                Animated(y, entityIdx * 0.3)
            )
            state.totalEntities = state.totalEntities + 1
            entityIdx = entityIdx + 1
        end
    end

    -- Spawn grid of diamonds
    for row = 0, 4 do
        for col = 0, 4 do
            local x = 700 + col * 100
            local y = 200 + row * 100
            world:spawn(
                Transform(x, y, 0, 2),
                Mesh("diamond"),
                Color(0.8, 0.5 + col / 10, 0.5 + row / 10, 1),
                Animated(y, entityIdx * 0.3)
            )
            state.totalEntities = state.totalEntities + 1
            entityIdx = entityIdx + 1
        end
    end

    -- Static corner lights
    world:spawn(Transform(100, 100), Light(500, 2.0, 0.4, 1.0, 0.7, 0.5))
    world:spawn(Transform(WORLD_WIDTH - 100, 100), Light(500, 2.0, 0.4, 0.5, 0.7, 1.0))
    world:spawn(Transform(100, WORLD_HEIGHT - 100), Light(500, 2.0, 0.4, 0.7, 1.0, 0.5))
    world:spawn(Transform(WORLD_WIDTH - 100, WORLD_HEIGHT - 100), Light(500, 2.0, 0.4, 1.0, 0.5, 0.7))

    -- Mouse-following light
    state.mouseLightEntity = world:spawn(
        Transform(WORLD_WIDTH / 2, WORLD_HEIGHT / 2),
        Light(350, 2.5, 0.3, 1.0, 0.95, 0.85)
    )

    -- Animation system
    local animQuery = world:query({
        name = "AnimatedMeshes",
        include = {Animated, Transform}
    })

    world:addSystem({
        name = "AnimateMeshes",
        phase = tecs.phases.Update,
        run = function()
            local time = love.timer.getTime() - startTime
            for archetype, len in animQuery:iter() do
                local transforms = archetype:getMut(Transform)
                local animateds = archetype:get(Animated)
                for i = 1, len do
                    local t = transforms[i]
                    local anim = animateds[i]
                    t.y = anim.baseY + math.sin(time * 2 + anim.offset) * 15
                end
            end
        end
    })

    -- Mouse light tracking
    world:addSystem({
        name = "MouseLightTracker",
        phase = tecs.phases.Update,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local mx, my = input.mouseX, input.mouseY
            local wx, wy = s.pipeline:getCamera():toWorld(mx, my)
            s.mouseWorldX = wx
            s.mouseWorldY = wy

            local transform = world:get(s.mouseLightEntity, Transform)
            if transform then
                transform.x = wx
                transform.y = wy
            end
        end
    })

    -- Dynamic spawn/despawn test
    local spawnTimer = 0.0
    local despawnQueue: {integer} = {}

    world:addSystem({
        name = "DynamicSpawnTest",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end

            spawnTimer = spawnTimer + dt
            if spawnTimer > 2.0 then
                spawnTimer = 0
                -- Use current world bounds for spawning
                local x = math.random(s.worldMinX as integer + 100, s.worldMaxX as integer - 100)
                local y = math.random(s.worldMinY as integer + 100, s.worldMaxY as integer - 100)
                local meshType = math.random() > 0.5 and "triangle" or "diamond"
                local entityId = world:spawn(
                    Transform(x, y, 0, 2),
                    Mesh(meshType),
                    Color(math.random(), math.random(), math.random(), 1)
                )
                s.totalEntities = s.totalEntities + 1
                table.insert(despawnQueue, entityId)

                if #despawnQueue > 10 then
                    local oldEntity = table.remove(despawnQueue, 1)
                    if world:isAlive(oldEntity) then
                        world:despawn(oldEntity)
                        s.totalEntities = s.totalEntities - 1
                    end
                end
            end
        end
    })

    -- Input handling
    world:addSystem({
        name = "Input",
        phase = tecs.phases.First,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end
            local p = s.pipeline
            local cam = p:getCamera()

            -- Camera pan
            if input.isKeyDown("d") or input.isKeyDown("right") then
                cam:nudge(CAMERA_SPEED * dt, 0)
            end
            if input.isKeyDown("a") or input.isKeyDown("left") then
                cam:nudge(-CAMERA_SPEED * dt, 0)
            end
            if input.isKeyDown("s") or input.isKeyDown("down") then
                cam:nudge(0, CAMERA_SPEED * dt)
            end
            if input.isKeyDown("w") or input.isKeyDown("up") then
                cam:nudge(0, -CAMERA_SPEED * dt)
            end

            -- Zoom
            if input.isKeyDown("=") or input.isKeyDown("+") then
                cam:setZoom(cam:getZoom() * (1 + dt))
            elseif input.isKeyDown("-") then
                cam:setZoom(cam:getZoom() * (1 - dt))
            end

            -- Reset
            if input.isKeyReleased("r") then
                cam:setPosition(WORLD_WIDTH / 2, WORLD_HEIGHT / 2)
                cam:setZoom(0.8)
            end

            -- Spawn more meshes with space (expanding world bounds each time)
            if input.isKeyReleased("space") then
                -- Expand world bounds by 500 in each direction
                s.worldMinX = s.worldMinX - 500
                s.worldMinY = s.worldMinY - 500
                s.worldMaxX = s.worldMaxX + 500
                s.worldMaxY = s.worldMaxY + 500

                -- Spawn 100 meshes spread across the expanded area
                for _ = 1, 100 do
                    local x = math.random(s.worldMinX as integer, s.worldMaxX as integer)
                    local y = math.random(s.worldMinY as integer, s.worldMaxY as integer)
                    local meshType = math.random() > 0.5 and "triangle" or "diamond"
                    world:spawn(
                        Transform(x, y, 0, 2),
                        Mesh(meshType),
                        Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, 1)
                    )
                    s.totalEntities = s.totalEntities + 1
                end
            end

            -- Update HUD text
            local zoom = cam:getZoom()
            local text = world:get(s.zoomTextEntity, Text)
            if text then
                text:setText(string.format("Meshes: %d | Zoom: %.2fx", s.totalEntities, zoom))
            end
        end
    })
end


love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        meshDemoPlugin(world)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = false,
        lightingMode = "deferred",
        cameraPosition = {WORLD_WIDTH / 2, WORLD_HEIGHT / 2},
        zoom = 0.8,
        ambientLight = {0.4, 0.4, 0.4},
        layers = {
            [2] = { name = "meshes" },
            [HUD_LAYER] = { name = "hud", space = "virtual", unlit = true },
        },
    },
})
