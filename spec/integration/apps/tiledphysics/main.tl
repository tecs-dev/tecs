--- Tiled + physics fixture: an inline-built tilemap (no asset files)
--- spawned at a non-zero Transform, with gravity and a ball dropped above
--- the map's floor row. Collision geometry must land where the map
--- renders (offset by the entity's Transform), so the ball comes to rest
--- on the floor; if collision ignores the Transform, the ball falls
--- straight through.
---
--- Layout: 6x4 map of 16px tiles at Transform (200, 80). The bottom row
--- is solid green tiles, spanning world (200..296, 128..144). The ball
--- (radius 8) drops from (248, 40) and should rest at y = 120.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local gfx <const> = require("tecs2d.gfx")
local tiled <const> = require("tecs2d.tiled")
local physics <const> = require("tecs2d.physics")

local Transform <const> = tecs.builtins.Transform

local MAP_X <const> = 200
local MAP_Y <const> = 80

local function buildMap(): tiled.TilemapData
    local solidTile: {string: any} = {
        id = 0,
        objectgroup = {
            type = "objectgroup",
            draworder = "index",
            name = "collision",
            objects = {{
                id = 1, name = "", type = "",
                x = 0, y = 0, width = 16, height = 16,
                rotation = 0, visible = true,
            }},
        },
    }
    local mapData: {string: any} = {
        width = 6, height = 4,
        tilewidth = 16, tileheight = 16,
        layers = {{
            type = "tilelayer", name = "floor",
            visible = true, opacity = 1,
            width = 6, height = 4,
            data = {
                0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
                1, 1, 1, 1, 1, 1,
            },
        }},
        tilesets = {{
            firstgid = 1, name = "solid",
            tilewidth = 16, tileheight = 16,
            tilecount = 1, columns = 1,
            image = "inline", imagewidth = 16, imageheight = 16,
            tiles = {solidTile},
        }},
    }
    local map = tiled.parseTiledMap(mapData)

    -- The file loader normally loads the tileset image; supply a solid
    -- green one directly since this map never touches disk.
    local imageData = love.image.newImageData(16, 16)
    for y = 0, 15 do
        for x = 0, 15 do
            imageData:setPixel(x, y, 0, 1, 0, 1)
        end
    end
    local image = love.graphics.newImage(imageData)
    image:setFilter("nearest", "nearest")
    map.tilesets[1].image = image as love.graphics.Texture
    return map
end

local function gamePlugin(world: tecs.World)
    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    world:addPlugin(physics.new({
        world = love.physics.newWorld(0, 300, true),
    }))

    -- Debug overlay installed but disabled; the collision spec toggles
    -- it via PhysicsDebugToggle to cover the lazy buffer path.
    world:addPlugin(gfx.physicsDebug.new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(160, 120)

    world:spawn(
        tiled.Tilemap.new({
            data = buildMap(),
            collision = {enabled = true},
        } as {string: any}) as tecs.Component,
        Transform(MAP_X, MAP_Y, 0, 1) as tecs.Component
    )

    local globals = _G as {string: any}
    globals.tecsTestBall = world:spawn(
        Transform(248, 40, 0, 1) as tecs.Component,
        physics.Collider.new({shape = "circle", radius = 8}) as tecs.Component,
        physics.RigidBody.new({mass = 1}) as tecs.Component
    )
end

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 240,
        lightingMode = "none",
    },
})
