--- Demonstrates mesh residency and extraction before mesh drawing exists.
---
--- The cube is a real 3D entity carrying `Transform3D`, `Mesh`, `Bounds3D`,
--- `Material`, and `Renderable3D`. Its indexed geometry is registered in the
--- mesh domain and extracted into mesh-owned GPU staging. Until the opaque
--- mesh pass lands, the example also projects the cube through `Camera3D` and
--- draws that result through the existing 2D sprite domain.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform2D <const> = tecs.Transform2D
local Transform3D <const> = tecs.Transform3D
local Material <const> = tecs.gfx.Material
local Tint <const> = tecs.gfx.Tint
local Renderable2D <const> = tecs.gfx.Renderable2D
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

local EDGES <const>: {{integer}} = {
    {1, 2},
    {2, 3},
    {3, 4},
    {4, 1},
    {5, 6},
    {6, 7},
    {7, 8},
    {8, 5},
    {1, 5},
    {2, 6},
    {3, 7},
    {4, 8},
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

local projectedX: {number} = {}
local projectedY: {number} = {}
for index = 1, #VERTICES do
    projectedX[index] = 0
    projectedY[index] = 0
end

local function game(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(1, {sort = "z", screenSpace = true, unlit = true})

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
    local cube <const> = world:spawn(Transform3D(), mesh, bounds, Material(), Renderable3D())

    local edgeEntities: {integer} = {}
    for index = 1, #EDGES do
        edgeEntities[index] = world:spawn(
            Transform2D(0, 0, index, 1, 0, 1, 3), Tint(0.25, 0.82, 1.0, 1.0), Renderable2D()
        )
    end

    local vertexEntities: {integer} = {}
    for index = 1, #VERTICES do
        vertexEntities[index] = world:spawn(
            Transform2D(0, 0, 20 + index, 1, 0, 8, 8), Tint(1.0, 0.72, 0.24, 1.0), Renderable2D()
        )
    end

    print("scene3d: one 8-vertex, 36-index mesh is resident in MeshDomain")
    print("scene3d: the cyan wireframe remains its transitional 2D projection")
    print("scene3d: the next stage records the resident geometry into the G-buffer")
    print("scene3d: escape or close the window to quit")

    local elapsed = 0.0
    world:addSystem({
        name = "example.RotateAndProject3D",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            elapsed = elapsed + dt
            local halfAngle <const> = elapsed * 0.35
            local transform <const> = world:getMut(cube, Transform3D)
            transform.rotationY = math.sin(halfAngle)
            transform.rotationW = math.cos(halfAngle)

            local width, height = app.window:getPixelSize()
            local matrix <const> = camera:matrix(width, height)
            local m0 <const> = matrix[0] as number
            local m1 <const> = matrix[1] as number
            local m3 <const> = matrix[3] as number
            local m4 <const> = matrix[4] as number
            local m5 <const> = matrix[5] as number
            local m7 <const> = matrix[7] as number
            local m8 <const> = matrix[8] as number
            local m9 <const> = matrix[9] as number
            local m11 <const> = matrix[11] as number
            local m12 <const> = matrix[12] as number
            local m13 <const> = matrix[13] as number
            local m15 <const> = matrix[15] as number
            local qy <const> = transform.rotationY
            local qw <const> = transform.rotationW
            local sinAngle <const> = 2.0 * qy * qw
            local cosAngle <const> = 1.0 - 2.0 * qy * qy

            for index = 1, #VERTICES do
                local vertex <const> = VERTICES[index]
                local x <const> = vertex[1] * transform.scaleX
                local y <const> = vertex[2] * transform.scaleY
                local z <const> = vertex[3] * transform.scaleZ
                local worldX <const> = transform.x + x * cosAngle + z * sinAngle
                local worldY <const> = transform.y + y
                local worldZ <const> = transform.z - x * sinAngle + z * cosAngle
                local clipX <const> = m0 * worldX + m4 * worldY + m8 * worldZ + m12
                local clipY <const> = m1 * worldX + m5 * worldY + m9 * worldZ + m13
                local clipW <const> = m3 * worldX + m7 * worldY + m11 * worldZ + m15
                projectedX[index] = (clipX / clipW * 0.5 + 0.5) * width
                projectedY[index] = (0.5 - clipY / clipW * 0.5) * height

                local marker <const> = world:getMut(vertexEntities[index], Transform2D)
                marker.x = projectedX[index]
                marker.y = projectedY[index]
            end

            for index = 1, #EDGES do
                local edge <const> = EDGES[index]
                local fromX <const> = projectedX[edge[1]]
                local fromY <const> = projectedY[edge[1]]
                local dx <const> = projectedX[edge[2]] - fromX
                local dy <const> = projectedY[edge[2]] - fromY
                local line <const> = world:getMut(edgeEntities[index], Transform2D)
                line.x = fromX + dx * 0.5
                line.y = fromY + dy * 0.5
                line.rotation = math.atan2(dy, dx)
                line.scaleX = math.sqrt(dx * dx + dy * dy)
            end
        end,
    })
end

return tecs.newApplication({
    window = {
        title = "Tecs 3D scene contract",
        width = 960,
        height = 640,
    },
    ambientLight = {1, 1, 1},
    capacity = 64,
    meshes = {
        capacity = 64,
        vertexCapacity = 1024,
        indexCapacity = 3072,
    },
    maxEntities = 64,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
