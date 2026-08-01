--- Draws vertex-colored PBR and unlit meshes through fog and bloom, with a 2D HUD.

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
local Transform2D <const> = tecs.Transform2D
local Renderable2D <const> = tecs.gfx.Renderable2D

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

local FLOOR_VERTICES <const>: {number} = {
    -5,
    0,
    -5,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    0,
    0,
    5,
    0,
    -5,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    0,
    5,
    0,
    5,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    1,
    -5,
    0,
    5,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    0,
    1,
}

local FLOOR_TRIANGLES <const>: {integer} = {0, 2, 1, 0, 3, 2}

local function game(world: tecs.World, app: tecs.Application)
    local meshDomain <const> = app.renderer.meshes
    local camera <const> = meshDomain.camera
    camera.y = 1.5
    camera.z = 7
    camera.rotationX = math.sin(math.rad(-12) * 0.5)
    camera.rotationW = math.cos(math.rad(-12) * 0.5)
    camera.verticalFov = math.rad(55)
    camera.near = 0.1
    camera.far = 100

    local meshVertices: {number} = {}
    local meshColors: {number} = {}
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
        local colorBase <const> = #meshColors
        meshColors[colorBase + 1] = vertex[1] * 0.25 + 0.65
        meshColors[colorBase + 2] = vertex[2] * 0.25 + 0.65
        meshColors[colorBase + 3] = vertex[3] * 0.25 + 0.65
        meshColors[colorBase + 4] = 1.0
    end

    local mesh, bounds = meshDomain:registerMesh(tecs.assets.newMesh({
        name = "example://unit-cube",
        vertices = meshVertices,
        indices = TRIANGLES,
        colors = meshColors,
    }))
    local pbr <const> = meshDomain:registerMaterial({
        name = "example://vertex-colored-pbr",
        model = meshDomain.MATERIAL_METALLIC_ROUGHNESS,
        metallic = 0.15,
        roughness = 0.55,
    })
    local cube <const> = world:spawn(Transform3D(), mesh, bounds, pbr, Tint(0.45, 0.9, 1.0, 1.0), Renderable3D())

    local glow <const> = meshDomain:registerMaterial({
        name = "example://unlit-glow",
        model = meshDomain.MATERIAL_UNLIT,
        baseR = 0.15,
        baseG = 0.55,
        baseB = 1.0,
        emissiveR = 0.25,
        emissiveG = 0.8,
        emissiveB = 1.0,
    })
    world:spawn(
        Transform3D.new({x = 2.5, y = 0.2, z = -3.0, scaleX = 0.6, scaleY = 0.6, scaleZ = 0.6}),
        mesh,
        bounds,
        glow,
        Tint(1, 1, 1, 1),
        Renderable3D()
    )

    local floor, floorBounds = meshDomain:registerMesh(tecs.assets.newMesh({
        name = "example://shadow-floor",
        vertices = FLOOR_VERTICES,
        indices = FLOOR_TRIANGLES,
    }))
    world:spawn(
        Transform3D.new({y = -1.1}), floor, floorBounds, MeshMaterial(), Tint(0.5, 0.53, 0.58, 1.0), Renderable3D()
    )

    -- Screen-space, unlit, and explicitly routed through the sprite forward
    -- lane after every mesh and bloom pass. This is the HUD recipe for a mixed
    -- 2D/3D application; tecs.ui produces the same 2D entities.
    tecs.gfx.layers.configure(16, {sort = "z", screenSpace = true, unlit = true, overlay = true})
    world:spawn(Transform2D(142, 44, 0, 16, 0, 252, 56), Tint(0.02, 0.04, 0.08, 1.0), Renderable2D())
    world:spawn(Transform2D(70, 44, 1, 16, 0, 88, 10), Tint(0.2, 0.9, 1.0, 1.0), Renderable2D())
    world:spawn(Transform2D(170, 44, 1, 16, 0, 88, 10), Tint(1.0, 0.45, 0.2, 1.0), Renderable2D())

    print("scene3d: vertex colors, PBR/unlit materials, fog, bloom, shadow, and 2D HUD")
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
        title = "Tecs 3D mesh shadows",
        width = 960,
        height = 640,
    },
    ambientLight = {0.12, 0.13, 0.16},
    capacity = 128,
    bloom = {scale = 0.5, threshold = 0.72, knee = 0.12, intensity = 0.65},
    meshes = {
        capacity = 64,
        vertexCapacity = 1024,
        indexCapacity = 3072,
        vertexColors = true,
        fog = {start = 8, finish = 32, r = 0.10, g = 0.14, b = 0.22},
        shadows = {
            scale = 1,
            distance = 12,
            directionX = -0.45,
            directionY = -1,
            directionZ = -0.3,
            intensity = 1.4,
            strength = 0.85,
            softness = 1.5,
        },
    },
    maxEntities = 8,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
