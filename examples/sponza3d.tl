--- Loads the pinned Khronos Sponza scene with mipmaps and local 3D lights.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform3D <const> = tecs.Transform3D
local PointLight3D <const> = tecs.gfx.PointLight3D
local SpotLight3D <const> = tecs.gfx.SpotLight3D
local FlyCamera3D <const> = tecs.gfx.FlyCamera3D
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    local camera <const> = meshes.camera
    -- Sponza's long gallery runs along X. Start inside it and look toward the
    -- center rather than placing the camera outside its positive-Z wall.
    camera.x = 6.0
    camera.y = 2.5
    camera.z = 0.0
    camera.rotationY = math.sin(math.rad(90) * 0.5)
    camera.rotationW = math.cos(math.rad(90) * 0.5)
    camera.verticalFov = math.rad(58)
    camera.near = 0.1
    camera.far = 120

    local controller <const> = FlyCamera3D.new(app.input, camera, {moveSpeed = 5, sprintMultiplier = 4})
    world:addSystem({
        name = "example.SponzaFlyCamera",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number) controller:update(dt) end,
    })

    local pointColors <const>: {{number}} = {
        {-8, 4.0, 1.5, 1.0, 0.48, 0.20},
        {0, 4.5, -1.0, 0.25, 0.52, 1.0},
        {8, 4.0, 1.5, 1.0, 0.32, 0.16},
    }
    for _, light in ipairs(pointColors) do
        world:spawn(
            Transform3D.new({x = light[1], y = light[2], z = light[3]}),
            PointLight3D(13, light[4], light[5], light[6], 6)
        )
    end
    world:spawn(
        Transform3D.new({
            x = 0,
            y = 11,
            z = -2,
            rotationX = math.sin(math.rad(-90) * 0.5),
            rotationW = math.cos(math.rad(-90) * 0.5),
        }),
        SpotLight3D(20, math.rad(18), math.rad(32), 0.75, 0.85, 1.0, 8)
    )

    local loaded <const> = tecs.assets.loadGLTF(tecs.io.files.assetPath("external/sponza/Sponza.tecs.gltf"))
    -- Strong colored point lights make this scene's eye-dependent specular
    -- response resemble a moving pool of light. Its visible architecture is
    -- predominantly masonry, cloth, and vegetation, so keep the texture's
    -- roughness variation but present it as a rough dielectric.
    for _, material in ipairs(loaded.materials) do
        material.metallic = 0.0
        material.roughness = 1.4
    end
    local instance <const> = meshes:registerModel(loaded):newInstance()
    for _, primitive in ipairs(instance.primitives) do
        world:spawn(
            primitive.transform, primitive.mesh, primitive.bounds, primitive.material, Tint(1, 1, 1, 1), Renderable3D()
        )
    end
    print(("sponza3d: loaded %d cullable primitives under point and spot lights"):format(#instance.primitives))
    print("sponza3d: click to look; WASD moves, Q/E changes height, Shift sprints, Tab releases")
end

return tecs.newApplication({
    window = {title = "Tecs Sponza lighting", width = 1280, height = 720},
    ambientLight = {0.08, 0.09, 0.11},
    sprites = false,
    bloom = {scale = 0.5, threshold = 0.55, knee = 0.18, intensity = 0.9},
    meshes = {
        capacity = 256,
        vertexCapacity = 262144,
        indexCapacity = 1048576,
        materialCapacity = 64,
        textureWidth = 1024,
        textureHeight = 1024,
        textureLayers = 72,
        packTextures = false,
        mipmaps = true,
        textureFormat = tecs.assets.IMAGE_BC3,
        doubleSided = true,
        lights = {capacity = 64},
        fog = {start = 45, finish = 90, r = 0.07, g = 0.09, b = 0.13},
        shadows = {
            scale = 1,
            distance = 42,
            directionX = -0.35,
            directionY = -1,
            directionZ = -0.25,
            r = 1.0,
            g = 0.88,
            b = 0.72,
            intensity = 1.0,
            strength = 0.75,
            softness = 1.5,
        },
    },
    maxEntities = 512,
    fixedMaxSteps = 240,
    presentMode = os.getenv("TECS_PRESENT") or "immediate",
    debug = true,
    showFps = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
