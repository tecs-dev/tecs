local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local SpriteSheet <const> = gfx.SpriteSheet
local mcp <const> = require("tecs2d.mcp")
local min <const> = math.min
local allPaused = false
local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"

-- Get spawn count from command line args or use default
local function getSpawnCount(): integer
    local args = love.arg.parseGameArguments(arg)
    if args[1] then
        local count = tonumber(args[1])
        if count and count > 0 then
            return count as integer
        end
    end
    return 10 * 1000
end

local SPAWN_COUNT <const> = getSpawnCount()

local function benchPlugin(world: tecs.World)
    local spawnCount = SPAWN_COUNT
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    local runnerSheet = SpriteSheet.fromFile("assets/running.png")

    world:addPlugin(require("tecs2d.debug").new())

    -- Spawn N runners in a grid pattern using bulk spawn
    -- Note: Each entity gets its own Sprite via Animation component's onAdd hook
    local gridSize = math.ceil(math.sqrt(spawnCount))
    local spacing = 40

    -- Calculate grid dimensions and center it at (0, 0)
    local gridWidth = (gridSize - 1) * spacing
    local gridHeight = (gridSize - 1) * spacing
    local startX = -(gridWidth / 2)
    local startY = -(gridHeight / 2)

    -- Bulk spawn sprites in a grid using batchSpawn. One Sprite value is
    -- copied into every row so setup avoids per-row allocations without
    -- depending on Sprite's storage layout.
    local sharedStartTime = pipeline:getTime()
    local probe = gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true, startTime = sharedStartTime})
    local Transform <const> = tecs.builtins.Transform
    local SpriteComponent <const> = gfx.Sprite
    world:batchSpawn(spawnCount,
        {Transform as tecs.Component, SpriteComponent as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            local transforms = arch:getMut(Transform)
            for i = startRow, lastRow do
                local idx = i - startRow
                local row = math.floor(idx / gridSize)
                local col = idx % gridSize
                local t = transforms[i]
                t.x = startX + (col * spacing)
                t.y = startY + (row * spacing)
                t.z = idx * 0.001
                t.layer = 2
                t.rotation = 0
                t.scaleX = 1
                t.scaleY = 1

                arch:set(i, probe)
            end
        end)

    local input = require("tecs2d.input")
    local cameraPanSpeed <const> = 1200
    local cameraZoomFactor <const> = 0.1  -- Proportional zoom factor

    world:addSystem({
        name = "CameraControls",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            local cam = pipeline:getCamera()
            -- Camera zoom controls (proportional to current zoom for smooth zooming at all scales)
            if input.isKeyDown("=") or input.isKeyDown("+") then
                local currentZoom = cam:getZoom()
                cam:setZoom(min(currentZoom * (1 + cameraZoomFactor), 30))
            elseif input.isKeyDown("-") then
                local currentZoom = cam:getZoom()
                cam:setZoom(currentZoom * (1 - cameraZoomFactor))  -- No minimum, pipeline clamps internally
            end

            -- Camera panning with arrow keys
            if input.isKeyDown("right") then
                cam:nudge(cameraPanSpeed * dt, 0)
            end
            if input.isKeyDown("left") then
                cam:nudge(-cameraPanSpeed * dt, 0)
            end
            if input.isKeyDown("down") then
                cam:nudge(0, cameraPanSpeed * dt)
            end
            if input.isKeyDown("up") then
                cam:nudge(0, -cameraPanSpeed * dt)
            end

        end
    })

    -- HUD using screen-space layer with Text
    -- Position at bottom: virtualHeight (600) - text height (~8px at scale 1.0) - margin (12px) = 580
    world:spawn(
        tecs.builtins.Transform(10, 580, 0, 3),
        Text(FONT_PATH, "Arrows:Pan +/-:Zoom Space:Pause ESC:Quit", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    -- Toggle pause/resume all sprites with space
    local pauseQuery = world:query({ include = {gfx.Sprite} })
    world:addSystem({
        name = "PauseControl",
        phase = tecs.phases.Update,
        run = function()
            if input.isKeyReleased("space") then
                allPaused = not allPaused
                local pauseTime = love.timer.getTime()
                for archetype, len in pauseQuery:iter() do
                    local sprites = archetype:getMut(gfx.Sprite)
                    for i = 1, len do
                        local s = sprites[i]
                        if allPaused then
                            s:pause(pauseTime)
                        else
                            s:resume()
                        end
                    end
                end
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    -- Default world cap is ~1M slots. Bump it so the bench can spawn
    -- past 1M sprites; ABSOLUTE_MAX_SLOT_COUNT in IdAllocator is 4M
    -- (the id format's hard ceiling). The +1024 covers HUD text and
    -- any other non-sprite entities the renderer / plugins create.
    maxEntities = SPAWN_COUNT + 1024,
    game = function(world: tecs.World)
        world:addPlugin(mcp.new())
        world:addPlugin(benchPlugin)
    end,
    render = {
        virtualHeight = 600,
        lightingMode = "deferred",
        ambientLight = {1, 1, 1},
        sizeHints = { sprites = SPAWN_COUNT + 1000 },
        layers = {
            [1] = { name = "background" },
            [2] = { name = "sprites" },
            [3] = { name = "hud", space = "screen" },
        },
    },
})
