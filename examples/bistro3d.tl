--- Loads the pinned Amazon Lumberyard Bistro exterior with an ambient probe.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform3D <const> = tecs.Transform3D
local PointLight3D <const> = tecs.gfx.PointLight3D
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    local camera <const> = meshes.camera

    -- Use the authored exterior camera. Its quaternion turns Tecs' negative-Z
    -- camera forward toward the street's positive-Z extent.
    camera.x = 9.1325
    camera.y = 2.6832
    camera.z = -26.1308
    camera.rotationX = 0.005614
    camera.rotationY = -0.986264
    camera.rotationZ = -0.034287
    camera.rotationW = -0.161484
    camera.verticalFov = math.rad(52)
    camera.near = 0.1
    camera.far = 250

    local lamps <const>: {{number}} = {
        {3.5, 4.0, -5.0, 1.0, 0.45, 0.16},
        {9.0, 3.5, 4.5, 1.0, 0.34, 0.12},
        {-7.0, 4.0, 12.0, 0.28, 0.48, 1.0},
        {16.0, 4.5, 18.0, 1.0, 0.55, 0.22},
    }
    for _, lamp in ipairs(lamps) do
        world:spawn(
            Transform3D.new({x = lamp[1], y = lamp[2], z = lamp[3]}),
            PointLight3D(12, lamp[4], lamp[5], lamp[6], 4)
        )
    end

    tecs.assets.loadGLTF(tecs.io.files.assetPath("external/bistro/Bistro.tecs.gltf")):onSettle(function(
        loaded: tecs.Future<tecs.assets.Model>
    )
        if loaded.status ~= "ready" then
            error("bistro3d: fetch the scene first with `cargo xtask fetch bistro`: " .. loaded.error, 0)
        end
        local instance <const> = meshes:registerModel(loaded.value):newInstance()
        for _, primitive in ipairs(instance.primitives) do
            world:spawn(
                primitive.transform,
                primitive.mesh,
                primitive.bounds,
                primitive.material,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
        end
        print(
            ("bistro3d: loaded %d GPU-cullable chunks, %d vertices, %d indices, %d materials, and %d textures"):format(
                #instance.primitives,
                meshes.vertexCount,
                meshes.indexCount,
                meshes.materialCount,
                meshes.textureCount
            )
        )
    end)
end

return tecs.newApplication({
    window = {title = "Tecs Bistro stress scene", width = 1280, height = 720},
    ambientLight = {0.025, 0.03, 0.04},
    sprites = false,
    bloom = {scale = 0.5, threshold = 0.82, knee = 0.12, intensity = 0.28},
    meshes = {
        capacity = 2048,
        vertexCapacity = 3100000,
        indexCapacity = 8600000,
        materialCapacity = 160,
        textureWidth = 512,
        textureHeight = 512,
        textureLayers = 280,
        packTextures = false,
        mipmaps = true,
        textureFormat = tecs.assets.IMAGE_BC3,
        lights = {capacity = 32},
        probe = {
            positiveX = {0.10, 0.115, 0.14},
            negativeX = {0.075, 0.085, 0.11},
            positiveY = {0.24, 0.30, 0.42},
            negativeY = {0.035, 0.025, 0.022},
            positiveZ = {0.13, 0.105, 0.09},
            negativeZ = {0.07, 0.085, 0.12},
            intensity = 3.0,
        },
        fog = {start = 80, finish = 180, r = 0.18, g = 0.22, b = 0.30},
        shadows = {
            scale = 1,
            distance = 70,
            directionX = -0.42,
            directionY = -1,
            directionZ = -0.26,
            r = 1.0,
            g = 0.86,
            b = 0.68,
            intensity = 2.1,
            strength = 0.78,
            softness = 1.25,
        },
    },
    maxEntities = 2200,
    framesInFlight = 2,
    fixedMaxSteps = 240,
    presentMode = os.getenv("TECS_PRESENT"),
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
