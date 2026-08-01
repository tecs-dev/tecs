--- Draws an indexed opaque mesh through the 3D rendering domain.

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

local VERTICES <const>: {{number}} = {
    {-1, -1, -1},
    {1, -1, -1},
    {1, 1, -1},
    {-1, 1, -1},
    {-1, -1, 1},
    {1, -1, 1},
    {1, 1, 1},
    {-1, 1, 1},
}

local TRIANGLES <const>: {integer} = {
    0,
    2,
    1,
    0,
    3,
    2,
    4,
    5,
    6,
    4,
    6,
    7,
    0,
    1,
    5,
    0,
    5,
    4,
    3,
    7,
    6,
    3,
    6,
    2,
    0,
    4,
    7,
    0,
    7,
    3,
    1,
    2,
    6,
    1,
    6,
    5,
}

local function game(world: tecs.World, app: tecs.Application)
    local meshDomain <const> = app.renderer.meshes
    local camera <const> = meshDomain.camera
    camera.z = 6
    camera.verticalFov = math.rad(55)
    camera.near = 0.1
    camera.far = 100

    local meshVertices: {number} = {}
    for index = 1, #VERTICES do
        local vertex <const> = VERTICES[index]
        local base <const> = #meshVertices
        local inverseLength <const> = 1.0 / math.sqrt(
            vertex[1] * vertex[1] + vertex[2] * vertex[2] + vertex[3] * vertex[3]
        )
        meshVertices[base + 1] = vertex[1]
        meshVertices[base + 2] = vertex[2]
        meshVertices[base + 3] = vertex[3]
        meshVertices[base + 4] = vertex[1] * inverseLength
        meshVertices[base + 5] = vertex[2] * inverseLength
        meshVertices[base + 6] = vertex[3] * inverseLength
        meshVertices[base + 7] = 1
        meshVertices[base + 8] = 0
        meshVertices[base + 9] = 0
        meshVertices[base + 10] = 1
        meshVertices[base + 11] = vertex[1] * 0.5 + 0.5
        meshVertices[base + 12] = vertex[2] * 0.5 + 0.5
    end

    local mesh, bounds = meshDomain:registerMesh(tecs.assets.newMesh({
        name = "example://unit-cube",
        vertices = meshVertices,
        indices = TRIANGLES,
    }))
    local cube <const> = world:spawn(
        Transform3D(), mesh, bounds, MeshMaterial(), Tint(0.2, 0.72, 1.0, 1.0), Renderable3D()
    )

    print("scene3d: drawing one resident 8-vertex, 36-index opaque mesh")
    print("scene3d: escape or close the window to quit")

    local elapsed = 0.0
    world:addSystem({
        name = "example.Rotate3D",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            elapsed = elapsed + dt
            local halfAngle <const> = elapsed * 0.35
            local transform <const> = world:getMut(cube, Transform3D)
            transform.rotationY = math.sin(halfAngle)
            transform.rotationW = math.cos(halfAngle)
        end,
    })
end

return tecs.newApplication({
    window = {
        title = "Tecs opaque 3D mesh",
        width = 960,
        height = 640,
    },
    ambientLight = {1, 1, 1},
    sprites = false,
    meshes = {
        capacity = 64,
        vertexCapacity = 1024,
        indexCapacity = 3072,
    },
    maxEntities = 8,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
