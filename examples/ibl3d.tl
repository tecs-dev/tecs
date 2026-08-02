--- Compares metallic-roughness materials under a CC0 specular environment.

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

local function sphere(name: string, slices: integer, stacks: integer): tecs.assets.Mesh
    local vertices: {number} = {}
    local indices: {integer} = {}
    for row = 0, stacks do
        local v <const> = row / stacks
        local latitude <const> = v * math.pi
        local ring <const> = math.sin(latitude)
        local y <const> = math.cos(latitude)
        for column = 0, slices do
            local u <const> = column / slices
            local longitude <const> = u * math.pi * 2.0
            local x <const> = ring * math.cos(longitude)
            local z <const> = ring * math.sin(longitude)
            local base <const> = #vertices
            vertices[base + 1], vertices[base + 2], vertices[base + 3] = x, y, z
            vertices[base + 4], vertices[base + 5], vertices[base + 6] = x, y, z
            vertices[base + 7], vertices[base + 8], vertices[base + 9], vertices[base + 10] = -math.sin(
                longitude
            ),
                0.0,
                math.cos(longitude),
                1.0
            vertices[base + 11], vertices[base + 12] = u, v
        end
    end
    local stride <const> = slices + 1
    for row = 0, stacks - 1 do
        for column = 0, slices - 1 do
            local a <const> = row * stride + column
            local b <const> = a + stride
            local base <const> = #indices
            indices[base + 1], indices[base + 2], indices[base + 3] = a, a + 1, b
            indices[base + 4], indices[base + 5], indices[base + 6] = a + 1, b + 1, b
        end
    end
    assert(#indices == slices * stacks * 6)
    return assets.newMesh({name = name, vertices = vertices, indices = indices})
end

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    local camera <const> = meshes.camera
    camera.y, camera.z = 1.2, 10.5
    camera.rotationX = math.sin(math.rad(-6) * 0.5)
    camera.rotationW = math.cos(math.rad(-6) * 0.5)
    camera.verticalFov = math.rad(52)
    camera.near, camera.far = 0.1, 100

    local controller <const> = FlyCamera3D.new(app.input, camera, {moveSpeed = 4, sprintMultiplier = 4})
    world:addSystem({
        name = "example.IblFlyCamera",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number) controller:update(dt) end,
    })

    world:spawn(Transform3D.new({x = -4.5, y = 5.0, z = 4.0}), PointLight3D(16, 1.0, 0.72, 0.46, 8.0))
    world:spawn(Transform3D.new({x = 5.0, y = 2.5, z = 3.0}), PointLight3D(14, 0.34, 0.55, 1.0, 5.0))

    local mesh, bounds <const> = meshes:registerMesh(sphere("example://ibl-sphere", 40, 24))
    local roughness <const>: {number} = {0.05, 0.18, 0.32, 0.48, 0.65}
    for index, value in ipairs(roughness) do
        local material <const> = meshes:registerMaterial({
            name = ("example://ibl-metal-%d"):format(index),
            metallic = 1.0,
            roughness = value,
            baseR = 0.82,
            baseG = 0.62,
            baseB = 0.22,
        })
        world:spawn(
            Transform3D.new({x = (index - 3) * 2.15, y = 1.15}),
            mesh,
            bounds,
            material,
            Tint(1, 1, 1, 1),
            Renderable3D()
        )
        local dielectric <const> = meshes:registerMaterial({
            name = ("example://ibl-dielectric-%d"):format(index),
            metallic = 0.0,
            roughness = value,
            baseR = 0.18,
            baseG = 0.48,
            baseB = 0.92,
        })
        world:spawn(
            Transform3D.new({x = (index - 3) * 2.15, y = -1.15}),
            mesh,
            bounds,
            dielectric,
            Tint(1, 1, 1, 1),
            Renderable3D()
        )
    end

    local faceNames <const>: {string} = {
        "positive-x.svg",
        "negative-x.svg",
        "positive-y.svg",
        "negative-y.svg",
        "positive-z.svg",
        "negative-z.svg",
    }
    local loading: {tecs.Future<tecs.assets.Image>} = {}
    for index, face in ipairs(faceNames) do
        loading[index] = assets.loadImage(files.assetPath("environment/ibl-demo/" .. face))
    end
    tecs.Future.all(loading):onSettle(function(loaded: tecs.Future<{tecs.assets.Image}>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        local images <const> = loaded.value
        meshes:registerEnvironment({
            positiveX = images[1],
            negativeX = images[2],
            positiveY = images[3],
            negativeY = images[4],
            positiveZ = images[5],
            negativeZ = images[6],
        })
        print("ibl3d: loaded six CC0 environment faces and generated the roughness mip chain")
    end)

    print("ibl3d: upper row is gold metal, lower row is blue dielectric")
    print("ibl3d: roughness runs 0.05, 0.18, 0.32, 0.48, 0.65 from left to right")
    print("ibl3d: click to look; WASD moves, Q/E changes height, Shift sprints, Tab releases")
end

return tecs.newApplication({
    window = {title = "Tecs specular IBL", width = 1100, height = 700},
    ambientLight = {0.015, 0.018, 0.025},
    sprites = false,
    bloom = {scale = 0.35, threshold = 0.72, knee = 0.18, intensity = 0.55},
    meshes = {
        capacity = 16,
        vertexCapacity = 1200,
        indexCapacity = 6000,
        materialCapacity = 16,
        lights = {capacity = 4},
        probe = {
            positiveX = {0.11, 0.08, 0.07},
            negativeX = {0.05, 0.07, 0.11},
            positiveY = {0.18, 0.24, 0.34},
            negativeY = {0.025, 0.018, 0.016},
            positiveZ = {0.14, 0.09, 0.06},
            negativeZ = {0.045, 0.055, 0.09},
            intensity = 8.0,
        },
        environment = {size = 64, intensity = 2.4, skyboxIntensity = 0.35, rotation = math.rad(18)},
    },
    maxEntities = 16,
    framesInFlight = 2,
    presentMode = os.getenv("TECS_PRESENT") or "immediate",
    showFps = true,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
