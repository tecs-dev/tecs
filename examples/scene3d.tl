--- Demonstrates the 3D scene contract before mesh rendering exists.
---
--- The cube is a real 3D entity carrying `Transform3D`, `Mesh`, `Bounds3D`,
--- `Material`, and `Renderable3D`. Until `MeshDomain` lands, the engine does
--- not submit that entity to the GPU. This example projects the cube's local
--- bounds through `Camera3D` and draws the result through the existing 2D
--- sprite domain so the transform and camera contract can be inspected now.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform2D <const> = tecs.Transform2D
local Transform3D <const> = tecs.Transform3D
local Mesh <const> = tecs.gfx.Mesh
local Bounds3D <const> = tecs.gfx.Bounds3D
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

local projectedX: {number} = {}
local projectedY: {number} = {}
for index = 1, #VERTICES do
    projectedX[index] = 0
    projectedY[index] = 0
end

local function game(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(1, {sort = "z", screenSpace = true, unlit = true})

    local camera <const> = tecs.gfx.newCamera3D({
        z = 6,
        verticalFov = math.rad(55),
        near = 0.1,
        far = 100,
    })
    local cube <const> = world:spawn(
        Transform3D(),
        Mesh(tecs.gfx.meshId("example://unit-cube")),
        Bounds3D(0, 0, 0, math.sqrt(3)),
        Material(),
        Renderable3D()
    )

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

    print("scene3d: the cyan wireframe is a 2D projection of one 3D mesh entity")
    print("scene3d: MeshDomain does not draw the mesh yet")
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
    maxEntities = 64,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
