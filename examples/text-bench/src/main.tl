--- Text Benchmark
--- Renders text instances with various transforms.
--- Uses pre-allocated GPU buffers to prevent IOGPUDeviceShmem crashes on macOS.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local input <const> = require("tecs2d.input")
local floor <const> = require("floor")

local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"

local random <const> = math.random
local pi <const> = math.pi

-- Pool of random strings to choose from
local STRING_POOL <const>: {string} = {
    "Hello",
    "World",
    "ECS",
    "Lua",
    "Test",
    "Fast!",
    "GPU",
    "Tecs",
    "Score",
    "Level",
}

-- Configuration: defaults to 100 entities, can be overridden via command line
local function getSpawnCount(): integer
    local args = love.arg.parseGameArguments(arg)
    if args[1] then
        local count = tonumber(args[1])
        if count and count > 0 then
            return count as integer
        end
    end
    return 100
end

local SPAWN_COUNT <const> = getSpawnCount()
local WORLD_SIZE <const> = math.max(2000, math.floor(math.sqrt(SPAWN_COUNT) * 80))
local CAMERA_SPEED <const> = math.max(1000, WORLD_SIZE / 5)
local MAX_GLYPHS <const> = SPAWN_COUNT * 8 + 100

local function benchPlugin(world: tecs.World)
    local spawnCount = SPAWN_COUNT
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new())

    -- Spawn checkered floor
    floor.spawnCheckered(world, {
        worldWidth = WORLD_SIZE + 2048,
        worldHeight = WORLD_SIZE + 2048,
        tileSize = 400,
        layer = 1,
        offsetX = -1024,
        offsetY = -1024,
    })

    -- Bulk spawn text entities. `Text.init` writes its FFI fields and
    -- registers pending-spawn metadata in place, so we can call it
    -- inside a batchSpawn callback against the canonical column rather
    -- than allocating a temporary Text per entity.
    local startTime = love.timer.getTime()
    local stringCount = #STRING_POOL
    local Transform <const> = tecs.builtins.Transform
    local Color <const> = gfx.Color

    world:batchSpawn(spawnCount,
        {Transform as tecs.Component, Text as tecs.Component, Color as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            local transforms = arch:getMut(Transform)
            local texts = arch:getMut(Text)
            local colors = arch:getMut(Color)
            for i = startRow, lastRow do
                local t = transforms[i]
                t.x = random(0, WORLD_SIZE)
                t.y = random(0, WORLD_SIZE)
                t.z = 0
                t.layer = 2
                if random() < 0.3 then
                    t.rotation = random() * pi * 2
                else
                    t.rotation = 0
                end
                local scale = 0.5 + random() * 0.5
                t.scaleX = scale
                t.scaleY = scale

                Text.init(texts[i], FONT_PATH, STRING_POOL[random(1, stringCount)], 1)

                local c = colors[i]
                c.r = 0.5 + random() * 0.5
                c.g = 0.5 + random() * 0.5
                c.b = 0.5 + random() * 0.5
                c.a = 1
            end
        end)
    world:commit()

    local endTime = love.timer.getTime()
    print(string.format("[text-bench] Spawned %d text entities in %.3f seconds", spawnCount, endTime - startTime))

    -- Query for text entities (excludes HUD)
    local textQuery = world:query({
        name = "TextEntities",
        include = {Text, gfx.Color},
    })

    -- Camera controls
    world:addSystem({
        name = "CameraControls",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            local cam = pipeline:getCamera()
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

            if input.isKeyDown("=") or input.isKeyDown("+") then
                local currentZoom = cam:getZoom()
                cam:setZoom(math.min(currentZoom * 1.05, 10))
            elseif input.isKeyDown("-") then
                local currentZoom = cam:getZoom()
                cam:setZoom(currentZoom * 0.95)
            end

            if input.isKeyReleased("f") then
                local fullscreen = love.window.getFullscreen()
                love.window.setFullscreen(not fullscreen, "desktop")
            elseif input.isKeyReleased("space") then
                -- Append "." to 1% of text entities to test incremental dirty updates
                local updateCount = 0
                for archetype, len in textQuery:iter() do
                    local texts = archetype:getMut(Text) as {gfx.Text}
                    for i = 1, len do
                        if random() < 0.01 then
                            local txt = texts[i]
                            txt:setText(txt:getText() .. ".")
                            updateCount = updateCount + 1
                        end
                    end
                end
                print(string.format("[text-bench] Updated %d text entities", updateCount))
            end
        end
    })

    -- HUD
    world:spawn(
        tecs.builtins.Transform(2, 160, 0, 4),
        Text(FONT_PATH, "WASD/Arrows:Pan | +/-:Zoom\nF:Fullscreen | ESC:Quit", 0.3),
        gfx.Color(0.5, 0.5, 0.5, 1),
        gfx.Pivot(0, 0)
    )
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(benchPlugin)
    end,
    render = {
        virtualHeight = 180,
        lerpingEnabled = true,
        lerpSpeed = 8,
        cameraPosition = {WORLD_SIZE / 2, WORLD_SIZE / 2},
        zoom = 0.5,
        sizeHints = {
            textGlyphs = MAX_GLYPHS,
            textEntities = SPAWN_COUNT + 10,
        },
        layers = {
            [1] = { name = "ground" },
            [2] = { name = "text" },
            [3] = { name = "effects" },
            [4] = { name = "hud", space = "virtual" },
        },
    },
})
