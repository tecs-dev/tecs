--- Shows directional, point, and spot shadows in one mesh domain.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local assets <const> = tecs.assets
local files <const> = tecs.io.files
local Transform3D <const> = tecs.Transform3D
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D
local FlyCamera3D <const> = tecs.gfx.FlyCamera3D
local PointLight3D <const> = tecs.gfx.PointLight3D
local SpotLight3D <const> = tecs.gfx.SpotLight3D
local LIGHT_CASTS_SHADOWS <const> = tecs.gfx.LIGHT_CASTS_SHADOWS

local CUBE_POSITIONS <const>: {{number}} = {
    {-1, -1, -1},
    {1, -1, -1},
    {1, 1, -1},
    {-1, 1, -1},
    {-1, -1, 1},
    {1, -1, 1},
    {1, 1, 1},
    {-1, 1, 1},
}
local CUBE_INDICES <const>: {integer} = {
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

local function cube(): tecs.assets.Mesh
    local vertices: {number} = {}
    for _, position in ipairs(CUBE_POSITIONS) do
        local x <const>, y <const>, z <const> = position[1], position[2], position[3]
        local inverseLength <const> = 1.0 / math.sqrt(x * x + y * y + z * z)
        local base <const> = #vertices
        vertices[base + 1], vertices[base + 2], vertices[base + 3] = x, y, z
        vertices[base + 4], vertices[base + 5], vertices[base + 6] = x * inverseLength,
            y * inverseLength,
            z * inverseLength
        vertices[base + 7], vertices[base + 8], vertices[base + 9], vertices[base + 10] = 1, 0, 0, 1
        vertices[base + 11], vertices[base + 12] = x * 0.5 + 0.5, z * 0.5 + 0.5
    end
    return assets.newMesh({name = "example://shadow-cube", vertices = vertices, indices = CUBE_INDICES})
end

local function ground(): tecs.assets.Mesh
    return assets.newMesh({
        name = "example://shadow-ground",
        vertices = {
            -12,
            0,
            8,
            0,
            1,
            0,
            1,
            0,
            0,
            1,
            0,
            0,
            12,
            0,
            8,
            0,
            1,
            0,
            1,
            0,
            0,
            1,
            1,
            0,
            12,
            0,
            -100,
            0,
            1,
            0,
            1,
            0,
            0,
            1,
            1,
            1,
            -12,
            0,
            -100,
            0,
            1,
            0,
            1,
            0,
            0,
            1,
            0,
            1,
        },
        indices = {0, 2, 1, 0, 3, 2},
    })
end

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    local camera <const> = meshes.camera
    camera.y, camera.z = 3.2, 8
    camera.rotationX = math.sin(math.rad(-13) * 0.5)
    camera.rotationW = math.cos(math.rad(-13) * 0.5)
    camera.verticalFov = math.rad(58)
    camera.near, camera.far = 0.1, 140

    local controller <const> = FlyCamera3D.new(app.input, camera, {moveSpeed = 9, sprintMultiplier = 4})
    world:addSystem({
        name = "example.ShadowFlyCamera",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number) controller:update(dt) end,
    })

    local floorMesh, floorBounds <const> = meshes:registerMesh(ground())
    local cubeMesh, cubeBounds <const> = meshes:registerMesh(cube())
    local floorMaterial <const> = meshes:registerMaterial({
        name = "example://shadow-floor",
        baseR = 0.34,
        baseG = 0.38,
        baseB = 0.42,
        roughness = 0.72,
    })
    local pillarMaterial <const> = meshes:registerMaterial({
        name = "example://shadow-pillars",
        baseR = 0.76,
        baseG = 0.42,
        baseB = 0.18,
        metallic = 0.08,
        roughness = 0.4,
    })
    world:spawn(Transform3D(), floorMesh, floorBounds, floorMaterial, Tint(1, 1, 1, 1), Renderable3D())

    local depths <const>: {number} = {-3, -10, -22, -40, -64, -86}
    for index, z in ipairs(depths) do
        world:spawn(
            Transform3D.new({
                x = index % 2 == 0 and 2.8 or -2.8,
                y = 1.5 + index * 0.08,
                z = z,
                scaleX = 0.75,
                scaleY = 1.5 + index * 0.16,
                scaleZ = 0.75,
            }),
            cubeMesh,
            cubeBounds,
            pillarMaterial,
            Tint(1, 1, 1, 1),
            Renderable3D()
        )
    end

    world:spawn(
        Transform3D.new({x = -3.2, y = 3.4, z = -8}),
        PointLight3D.new({
            radius = 11,
            r = 1.0,
            g = 0.28,
            b = 0.12,
            intensity = 45,
            flags = LIGHT_CASTS_SHADOWS,
        })
    )
    world:spawn(
        Transform3D.new({
            x = 3.2,
            y = 6.5,
            z = -23,
            rotationX = math.sin(math.rad(-55) * 0.5),
            rotationW = math.cos(math.rad(-55) * 0.5),
        }),
        SpotLight3D.new({
            radius = 18,
            innerAngle = math.rad(18),
            outerAngle = math.rad(30),
            r = 0.18,
            g = 0.5,
            b = 1.0,
            intensity = 70,
            flags = LIGHT_CASTS_SHADOWS,
        })
    )

    local faceNames <const>: {string} = {
        "positive-x.svg",
        "negative-x.svg",
        "positive-y.svg",
        "negative-y.svg",
        "positive-z.svg",
        "negative-z.svg",
    }
    local images: {tecs.assets.Image} = {}
    for index, face in ipairs(faceNames) do
        images[index] = assets.loadImage(files.assetPath("environment/ibl-demo/" .. face))
    end
    meshes:registerEnvironment({
        positiveX = images[1],
        negativeX = images[2],
        positiveY = images[3],
        negativeY = images[4],
        positiveZ = images[5],
        negativeZ = images[6],
    })

    print("shadows3d: warm point and cool spot shadows join three directional cascades")
    print("shadows3d: click to look; WASD moves, Q/E changes height, Shift sprints, Tab releases")
end

return tecs.newApplication({
    window = {title = "Tecs directional and local shadows", width = 1100, height = 700},
    ambientLight = {0.035, 0.045, 0.065},
    sprites = false,
    bloom = {scale = 0.35, threshold = 0.8, knee = 0.2, intensity = 0.38},
    meshes = {
        capacity = 16,
        vertexCapacity = 64,
        indexCapacity = 64,
        materialCapacity = 4,
        lights = {
            capacity = 8,
            shadows = {capacity = 2, size = 256, bias = 0.002, softness = 1},
        },
        shadows = {
            distance = 100,
            splitLambda = 0.72,
            splitBlend = 0.12,
            depthPadding = 24,
            directionX = -0.55,
            directionY = -1,
            directionZ = -0.35,
            intensity = 4.0,
            strength = 0.92,
            softness = 1.0,
        },
        probe = {
            positiveX = {0.12, 0.08, 0.06},
            negativeX = {0.04, 0.055, 0.09},
            positiveY = {0.18, 0.22, 0.3},
            negativeY = {0.02, 0.025, 0.035},
            positiveZ = {0.15, 0.09, 0.055},
            negativeZ = {0.04, 0.05, 0.075},
            intensity = 2.0,
        },
        environment = {size = 64, intensity = 0.8, skyboxIntensity = 0.28},
    },
    maxEntities = 32,
    framesInFlight = 2,
    presentMode = os.getenv("TECS_PRESENT") or "immediate",
    showFps = true,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
