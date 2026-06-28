local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")
local floor <const> = require("floor")
local IdAllocator <const> = require("tecs.internal.IdAllocator")

local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"

-- Shape type from environment variable (default: rectangle)
local SHAPE <const> = os.getenv("SHAPE") or "rectangle"
local validShapes <const>: {string:boolean} = {
    rectangle = true,
    circle = true,
    ellipse = true,
    arc = true,
    line = true,
    mesh = true,
}
if not validShapes[SHAPE] then
    error("Invalid SHAPE: " .. SHAPE .. ". Valid shapes: rectangle, circle, ellipse, arc, line, mesh")
end

-- Definition name used by the mesh path. Registered inside the
-- showcase plugin before batchSpawn so `Mesh("bench")` resolves.
local MESH_DEFINITION_NAME <const> = "bench"

local lg <const> = love.graphics

local function createBenchMesh(): love.graphics.Mesh
    -- Equilateral-ish triangle, ~50 unit half-extent, vertex colors
    -- white so the entity's Color component drives final shading.
    local format: {{number | string}} = {
        {"VertexPosition", "float", 2},
        {"VertexTexCoord", "float", 2},
        {"VertexColor", "byte", 4},
    }
    local vertices: {{number}} = {
        { 0.0,   -50.0, 0.5, 0.0, 255, 255, 255, 255},
        { 43.3,   25.0, 1.0, 1.0, 255, 255, 255, 255},
        {-43.3,   25.0, 0.0, 1.0, 255, 255, 255, 255},
    }
    return lg.newMesh(format, vertices, "triangles", "static")
end

-- Configuration
local REQUESTED_TARGET <const> = (tonumber(os.getenv("ENTITIES")) or tonumber(arg[2]) or 100000) as integer
local MAX_LIVE_ENTITIES <const> = IdAllocator.ABSOLUTE_MAX_SLOT_COUNT - 1
local INITIAL_TARGET <const> = math.min(REQUESTED_TARGET, MAX_LIVE_ENTITIES)
local WORLD_SIZE <const> = math.max(5000, math.floor(math.sqrt(INITIAL_TARGET) * 35))

-- Entity arena sizing: headroom over INITIAL_TARGET so mid-run grows (I/U
-- keys add thousands more) don't crash against the cap. Take 1.5x the target
-- or 1M, whichever is larger; round up to a power of 2 (required by arena).
local function nextPow2(n: integer): integer
    local p = 1
    while p < n do p = p * 2 end
    return p
end
local DESIRED_MAX_ENTITIES <const> = nextPow2(math.max(math.floor(INITIAL_TARGET * 1.5), 1048576))
local MAX_ENTITIES <const> = math.min(DESIRED_MAX_ENTITIES, IdAllocator.ABSOLUTE_MAX_SLOT_COUNT)
local CAMERA_SPEED <const> = math.max(1000, WORLD_SIZE / 5)

local record ShowcaseState
    pipeline: gfx.Pipeline
    fullscreen: boolean
    currentEntityCount: integer
    colorCycleMode: boolean
    colorCycleTime: number
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<ShowcaseState>

if REQUESTED_TARGET ~= INITIAL_TARGET then
    print(string.format(
        "[shape-bench] Requested %d entities, clamped initial spawn to %d (allocator supports %d live entities per world)",
        REQUESTED_TARGET,
        INITIAL_TARGET,
        MAX_LIVE_ENTITIES
    ))
end

if DESIRED_MAX_ENTITIES ~= MAX_ENTITIES then
    print(string.format(
        "[shape-bench] Requested allocator headroom rounded to %d slots, clamped world maxEntities to %d",
        DESIRED_MAX_ENTITIES,
        MAX_ENTITIES
    ))
end

-- Get the component type for queries
local function getShapeComponentType(): tecs.Component
    if SHAPE == "rectangle" then
        return gfx.Rectangle as tecs.Component
    elseif SHAPE == "circle" then
        return gfx.Circle as tecs.Component
    elseif SHAPE == "ellipse" then
        return gfx.Ellipse as tecs.Component
    elseif SHAPE == "arc" then
        return gfx.Arc as tecs.Component
    elseif SHAPE == "line" then
        return gfx.Line as tecs.Component
    elseif SHAPE == "mesh" then
        return gfx.Mesh as tecs.Component
    end
    error("Unknown shape: " .. SHAPE)
end

local function showcasePlugin(world: tecs.World)
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    world:addPlugin(stats.newStatsPlugin())
    world:addPlugin(mcp.new())

    local state: ShowcaseState = {
        pipeline = pipeline,
        fullscreen = false,
        currentEntityCount = 0,
        colorCycleMode = false,
        colorCycleTime = 0,
    }

    world.resources[STATE_KEY] = state

    floor.spawnCheckered(world, {
        worldWidth = WORLD_SIZE + 2048,
        worldHeight = WORLD_SIZE + 2048,
        tileSize = 400,
        layer = 1,
        offsetX = -1024,
        offsetY = -1024,
    })

    -- Mesh path needs its definition registered before any
    -- `Mesh("bench")` constructs (which resolves the name → id at
    -- creation). Capacity is sized to the bench's spawn target so
    -- the per-definition output buffer doesn't churn-grow on the
    -- first cull dispatch.
    local benchDefId: integer = 0
    if SHAPE == "mesh" then
        local def = gfx.MeshDefinition.new(MESH_DEFINITION_NAME, createBenchMesh(), INITIAL_TARGET + 1024)
        benchDefId = def.id
    end

    -- Bulk spawn initial entities using batchSpawn for zero-allocation setup
    local startTime = love.timer.getTime()
    local Transform <const> = tecs.builtins.Transform
    local Color <const> = gfx.Color
    local shapeComp <const> = getShapeComponentType()
    world:batchSpawn(INITIAL_TARGET,
        {Transform as tecs.Component, shapeComp, Color as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            local transforms = arch:getMut(Transform)
            local shapes = arch:getMut(shapeComp)
            local colors = arch:getMut(Color)
            for i = startRow, lastRow do
                local t = transforms[i]
                t.x = math.random(0, WORLD_SIZE)
                t.y = math.random(0, WORLD_SIZE)
                t.layer = 2
                t.scaleX = 2
                t.scaleY = 2
                local c = colors[i]
                c.r = math.random() * 0.5 + 0.5
                c.g = math.random() * 0.5 + 0.5
                c.b = math.random() * 0.5 + 0.5
                c.a = 1
                if SHAPE == "rectangle" then
                    local s = shapes[i] as gfx.Rectangle
                    s.width = math.random(20, 100)
                    s.height = math.random(20, 100)
                elseif SHAPE == "circle" then
                    local s = shapes[i] as gfx.Circle
                    s.radius = math.random(10, 50)
                elseif SHAPE == "ellipse" then
                    local s = shapes[i] as gfx.Ellipse
                    s.radiusX = math.random(15, 60)
                    s.radiusY = math.random(10, 40)
                elseif SHAPE == "arc" then
                    local s = shapes[i] as gfx.Arc
                    s.radiusX = math.random(15, 60)
                    s.radiusY = math.random(10, 40)
                    s.startAngle = 0
                    s.endAngle = math.pi * 1.5
                    s.lineWidth = math.random(2, 6)
                elseif SHAPE == "line" then
                    local s = shapes[i] as gfx.Line
                    local len = math.random(30, 120)
                    local ang = math.random() * math.pi * 2
                    local hx = math.cos(ang) * len * 0.5
                    local hy = math.sin(ang) * len * 0.5
                    s.x1 = -hx
                    s.y1 = -hy
                    s.x2 = hx
                    s.y2 = hy
                    s.width = math.random(2, 6)
                elseif SHAPE == "mesh" then
                    -- Geometry is per-definition; vary only the per-row
                    -- transform scale so the visual density matches
                    -- shape-bench's other paths.
                    local s = shapes[i] as gfx.Mesh
                    s._definitionId = benchDefId
                    t.scaleX = (math.random() * 1.5) + 0.5
                    t.scaleY = (math.random() * 1.5) + 0.5
                end
            end
        end)
    world:commit()
    state.currentEntityCount = INITIAL_TARGET
    local endTime = love.timer.getTime()
    print(string.format("[shape-bench:%s] Spawned %d entities in %.3f seconds", SHAPE, INITIAL_TARGET, endTime - startTime))

    -- Query for color cycling (shapes with Color component)
    local shapeType = getShapeComponentType()
    local colorQuery = world:query({ include = { shapeType, Color } })

    -- Color column record for direct FFI access
    local record ColorFFI
        r: number
        g: number
        b: number
        a: number
    end

    local sin <const> = math.sin

    -- Color cycling system - updates every shape's color every frame when enabled
    -- Optimized: directly modifies color column and marks all dirty at once
    world:addSystem({
        name = "ColorCycler",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s or not s.colorCycleMode then return end

            s.colorCycleTime = s.colorCycleTime + dt
            local t = s.colorCycleTime

            for archetype, len in colorQuery:iter() do
                -- Get direct access to color column
                local colors = archetype:getMut(Color) as {ColorFFI}

                for i = 1, len do
                    local c = colors[i]
                    -- Add per-entity variation based on row index
                    local offset = i * 0.01
                    c.r = (sin(t * 0.5 + offset) + 1) * 0.25 + 0.5
                    c.g = (sin(t * 0.7 + offset + 2) + 1) * 0.25 + 0.5
                    c.b = (sin(t * 0.9 + offset + 4) + 1) * 0.25 + 0.5
                end

                -- Color column was rewritten via direct cdata writes;
                -- the getMut above already flagged Color dirty.
            end
        end
    })

    local input = require("tecs2d.input")

    world:addSystem({
        name = "Input",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end
            local p = s.pipeline
            local cam = p:getCamera()

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

            if input.isKeyDown("=") or input.isKeyDown("+") then
                local currentZoom = cam:getZoom()
                cam:setZoom(math.min(currentZoom * 1.1, 10))
            elseif input.isKeyDown("-") then
                local currentZoom = cam:getZoom()
                cam:setZoom(currentZoom * 0.9)
            end

            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
            elseif input.isKeyReleased("f") then
                s.fullscreen = not s.fullscreen
                love.window.setFullscreen(s.fullscreen, "desktop")
            elseif input.isKeyReleased("c") then
                s.colorCycleMode = not s.colorCycleMode
                print(string.format("[shape-bench] Color cycle mode: %s", s.colorCycleMode and "ON" or "OFF"))
            end
        end
    })

    world:spawn(
        tecs.builtins.Transform(2, 160, 0, 4),
        Text(FONT_PATH, "WASD:Pan | +/-:Zoom | F:Fullscreen | C:Color Cycle | ESC:Quit", 0.2),
        gfx.Color(0.6, 0.6, 0.6, 1),
        gfx.Pivot(0, 0)
    )
end

love.run = tecs2d.run({
    fps = 60,
    maxEntities = MAX_ENTITIES,
    game = function(world: tecs.World)
        world:addPlugin(showcasePlugin)
    end,
    render = {
        virtualHeight = 180,
        lightingMode = "none",
        shadowsEnabled = false,
        lerpingEnabled = true,
        lerpSpeed = 8,
        cameraPosition = {WORLD_SIZE / 2, WORLD_SIZE / 2},
        zoom = 0.3,
        layers = {
            [1] = { name = "ground" },
            [2] = { name = "entities" },
            [3] = { name = "effects" },
            [4] = { name = "hud", space = "virtual" },
        },
    },
})
