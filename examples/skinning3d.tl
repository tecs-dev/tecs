--- Animates a two-joint mesh through the optional GPU skinning lane.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform3D <const> = tecs.Transform3D
local MeshMaterial <const> = tecs.gfx.MeshMaterial
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local IDENTITY <const>: {number} = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

local function palette(offset: number): {number}
    local values: {number} = {}
    for index = 1, 16 do
        values[index] = IDENTITY[index]
        values[index + 16] = IDENTITY[index]
    end
    values[29] = offset
    return values
end

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    meshes.camera.z = 3
    meshes.camera.verticalFov = math.rad(50)

    local mesh, sourceBounds = meshes:registerMesh(tecs.assets.newMesh({
        name = "example://two-joint-strip",
        vertices = {
            -0.35,
            -1,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            0,
            0,
            0.35,
            -1,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            1,
            0,
            0.35,
            1,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            1,
            1,
            -0.35,
            1,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            0,
            1,
        },
        indices = {0, 1, 2, 0, 2, 3},
        joints = {0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0},
        weights = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0},
    }))
    local skin <const> = meshes:registerSkin("example://two-joint-palette", palette(0))
    local bounds <const> = tecs.gfx.Bounds3D(
        sourceBounds.centerX, sourceBounds.centerY, sourceBounds.centerZ, sourceBounds.radius + 0.5
    )
    world:spawn(Transform3D(), mesh, bounds, MeshMaterial(), skin, Tint(0.2, 0.72, 1, 1), Renderable3D())

    local elapsed = 0.0
    world:addSystem({
        name = "example.AnimateSkin",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            elapsed = elapsed + dt
            meshes:updateSkin(skin, palette(math.sin(elapsed * 2) * 0.55))
        end,
    })

    print("skinning3d: animating one of two joints entirely in the mesh vertex stage")
    print("skinning3d: escape or close the window to quit")
end

return tecs.newApplication({
    window = {title = "Tecs GPU skinning", width = 960, height = 640},
    ambientLight = {1, 1, 1},
    sprites = false,
    meshes = {
        capacity = 16,
        vertexCapacity = 256,
        indexCapacity = 768,
        skinning = {jointCapacity = 32},
    },
    maxEntities = 8,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
