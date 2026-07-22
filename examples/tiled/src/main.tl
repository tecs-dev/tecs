--- Tiled Collision Example
---
--- Demonstrates tilemap collision with a player-controlled ball.
--- Uses per-tile collision shapes defined in the tileset.
--- Features lighting and click-to-remove tiles.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local tecs_tiled <const> = require("tecs2d.tiled")
local mcp <const> = require("tecs2d.mcp")

local physics <const> = require("tecs2d.physics")
local input <const> = require("tecs2d.input")

local lp <const> = love.physics

local Transform <const> = tecs.builtins.Transform
local Circle <const> = gfx.Circle
local Color <const> = gfx.Color
local Light <const> = gfx.Light
local Unlit <const> = gfx.Unlit
local Text <const> = gfx.Text
local Occluder <const> = gfx.Occluder

local FONT_PATH <const> = "assets/press-start-2p.fnt"
local VIRTUAL_HEIGHT <const> = 480
local type TileSourceData = tecs_tiled.TileSource
local TileSource <const> = tecs_tiled.TileSource
local Collider <const> = physics.Collider
local RigidBody <const> = physics.RigidBody

local TILE_SIZE <const> = 32
local BALL_RADIUS <const> = 12
local BALL_SPEED <const> = 300

local function demoPlugin(world: tecs.World)
    -- Initialize physics (required for tilemap collision)
    lp.setMeter(TILE_SIZE * 2)
    world:addPlugin(physics.new({
        world = lp.newWorld(0, 0, true),  -- No gravity for top-down
        debug = false,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Add physics debug rendering (neon green)
    world:addPlugin(gfx.physicsDebug.new({ r = 0.2, g = 1.0, b = 0.2, a = 0.9 }))

    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new())

    local playerId: integer
    local initialized = false
    local lightsSpawned = false
    local tilemapQuery = world:query({ include = {tecs_tiled.Tilemap} })

    -- Spawn tilemap
    world:addSystem({
        name = "demo.SpawnTilemap",
        phase = tecs.phases.Startup,
        run = function()
            world:spawn(
                tecs_tiled.Tilemap.new({
                    path = "level.tmj",
                    collision = {
                        enabled = true,
                    }
                }),
                Transform.new({ x = 0, y = 0 })
            )
        end
    })

    -- Initialize game once tilemap is loaded
    world:addSystem({
        name = "demo.InitGame",
        phase = tecs.phases.Update,
        run = function()
            if initialized then return end

            -- Check if tilemap is loaded
            for archetype, len in tilemapQuery:iter() do
                local tilemaps = archetype:get(tecs_tiled.Tilemap)
                for i = 1, len do
                    local data = tilemaps[i].data
                    if data then
                        initialized = true

                        -- Get map dimensions from tilemap
                        local mapWidth = data.width
                        local mapHeight = data.height
                        local tileWidth = data.tilewidth
                        local tileHeight = data.tileheight
                        local mapPixelWidth = mapWidth * tileWidth
                        local mapPixelHeight = mapHeight * tileHeight

                        -- Move camera to center
                        pipeline:getCamera():move(mapPixelWidth / 2, mapPixelHeight / 2)

                        -- Spawn player ball in the center
                        local centerX = mapPixelWidth / 2
                        local centerY = mapPixelHeight / 2
                        -- Spawn on layer 1 with z = 100.5 to match torches for proper y-sorting
                        playerId = world:spawn(
                            Transform.new({ x = centerX, y = centerY, z = 100.5, layer = 1 }),
                            Circle(BALL_RADIUS),
                            Color(0.4, 0.8, 1.0, 1),
                            Collider.new({ shape = "circle", radius = BALL_RADIUS }),
                            RigidBody.new({ mass = 1, restitution = 0.5, drag = 2 }),
                            Occluder.new({ height = 0.05 })
                        )

                        return
                    end
                end
            end
        end
    })

    -- Spawn lights for TileSource tiles (runs one frame after initialization)
    world:addSystem({
        name = "demo.SpawnLights",
        phase = tecs.phases.Update,
        run = function()
            if not initialized or lightsSpawned then return end
            lightsSpawned = true

            -- Find sprites with TileSource and spawn lights/add Unlit for light-emitting tiles
            local tileSourceQuery = world:query({ include = {TileSource, Transform} })
            for arch, tileLen, tileIds in tileSourceQuery:iter() do
                local tileSources = arch:get(TileSource) as {TileSourceData}
                local transforms = arch:get(Transform)
                for j = 1, tileLen do
                    local tileSource = tileSources[j]
                    local transform = transforms[j]
                    if tileSource.properties and tileSource.properties.light then
                        local props = tileSource.properties
                        local offsetY = (props.lightOffsetY as number) or 0
                        local radius = (props.lightRadius as number) or 100
                        local intensity = (props.lightIntensity as number) or 3.0
                        local r = (props.lightR as number) or 1.0
                        local g = (props.lightG as number) or 0.8
                        local b = (props.lightB as number) or 0.4
                        -- Spawn light at tile center (tile sprite transform is already centered)
                        world:spawn(
                            Transform.new({ x = transform.x, y = transform.y + offsetY, layer = 1 }),
                            Color(r, g, b, 0.9),
                            Light(radius, intensity, 0.04, r, g, b)
                        )
                        -- Mark sprite as Unlit (light-emitting tiles shouldn't be darkened)
                        world:set(tileIds[j], Unlit)
                    end
                end
            end
        end
    })

    -- Player movement
    world:addSystem({
        name = "demo.PlayerMovement",
        phase = tecs.phases.FixedUpdate,
        run = function(_dt: number)
            if not playerId then return end

            local collider = world:get(playerId, Collider)
            if not collider or not collider.body then return end

            local body = collider.body
            local vx, vy = 0, 0

            if input.isKeyDown("w") or input.isKeyDown("up") then vy = vy - BALL_SPEED end
            if input.isKeyDown("s") or input.isKeyDown("down") then vy = vy + BALL_SPEED end
            if input.isKeyDown("a") or input.isKeyDown("left") then vx = vx - BALL_SPEED end
            if input.isKeyDown("d") or input.isKeyDown("right") then vx = vx + BALL_SPEED end

            -- Apply velocity
            body:setLinearVelocity(vx, vy)
        end
    })

    -- Camera follow and input handling
    world:addSystem({
        name = "demo.CameraAndInput",
        phase = tecs.phases.Update,
        run = function(dt: number)
            if not playerId then return end

            local playerTransform = world:get(playerId, Transform)
            if playerTransform then
                pipeline:getCamera():move(playerTransform.x, playerTransform.y)
            end

            -- Toggle physics debug with P
            if input.isKeyPressed("p") then
                world:emit(0, gfx.PhysicsDebugToggle())
            end

            -- Toggle lighting with L
            if input.isKeyPressed("l") then
                if pipeline:isLightingEnabled() then
                    pipeline:disableLighting()
                else
                    pipeline:enableLighting()
                end
            end

            -- Zoom with +/- keys
            local cam = pipeline:getCamera()
            local zoomSpeed = 2.0  -- Per second
            local currentZoom = cam:getZoom()
            if input.isKeyDown("=") then
                cam:setZoom(currentZoom * (1 + zoomSpeed * dt))
            end
            if input.isKeyDown("-") then
                cam:setZoom(currentZoom * (1 - zoomSpeed * dt))
            end

            -- Click to remove tile
            if input.isMousePressed(1) then
                for archetype, len in tilemapQuery:iter() do
                    local tilemaps = archetype:get(tecs_tiled.Tilemap)
                    for i = 1, len do
                        local tmData = tilemaps[i].data
                        if tmData then
                            local worldX, worldY = cam:toWorld(input.mouseX, input.mouseY)
                            -- Remove wall tiles (tile 2), leave grass (tile 1)
                            if tmData:getTileAt(1, worldX, worldY) == 2 then
                                tmData:setTileAt(1, worldX, worldY, 1)  -- Replace wall with grass
                            end
                        end
                    end
                end
            end
        end
    })

    -- HUD text (static, left-aligned at bottom)
    world:spawn(
        Transform(10, VIRTUAL_HEIGHT - 30, 0, 10),
        Text(FONT_PATH, "WASD: Move | Click: Remove wall | +/-: Zoom\nP: Physics debug | L: Lighting | ESC: Quit", 0.5),
        Color(0.95, 0.65, 0.25, 1),
        gfx.Pivot(0, 0)
    )
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(demoPlugin)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = false,
        lightingMode = "deferred",
        cameraPosition = { 0, 0 },
        layers = {
            [10] = { name = "hud", space = "virtual" },
        },
    },
})
