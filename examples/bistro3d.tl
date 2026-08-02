--- Loads the pinned Amazon Lumberyard Bistro exterior with an ambient probe.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform3D <const> = tecs.Transform3D
local PointLight3D <const> = tecs.gfx.PointLight3D
local FlyCamera3D <const> = tecs.gfx.FlyCamera3D
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local INITIAL_DAYLIGHT <const> = 0.55
local DAYLIGHT_PER_WHEEL <const> = 0.08

local function mix(from: number, to: number, amount: number): number
    return from + (to - from) * amount
end

local function mixColor(
    color: {number},
    nightR: number,
    nightG: number,
    nightB: number,
    dayR: number,
    dayG: number,
    dayB: number,
    daylight: number
)
    color[1] = mix(nightR, dayR, daylight)
    color[2] = mix(nightG, dayG, daylight)
    color[3] = mix(nightB, dayB, daylight)
end

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

    local controller <const> = FlyCamera3D.new(app.input, camera, {moveSpeed = 7, sprintMultiplier = 4})
    world:addSystem({
        name = "example.BistroFlyCamera",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number) controller:update(dt) end,
    })

    local lamps <const>: {{number}} = {
        {3.5, 4.0, -5.0, 1.0, 0.45, 0.16},
        {9.0, 3.5, 4.5, 1.0, 0.34, 0.12},
        {-7.0, 4.0, 12.0, 0.28, 0.48, 1.0},
        {16.0, 4.5, 18.0, 1.0, 0.55, 0.22},
    }
    local lampEntities: {integer} = {}
    for _, lamp in ipairs(lamps) do
        lampEntities[#lampEntities + 1] = world:spawn(
            Transform3D.new({x = lamp[1], y = lamp[2], z = lamp[3]}), PointLight3D(12, lamp[4], lamp[5], lamp[6], 4)
        )
    end

    local daylight = INITIAL_DAYLIGHT
    local appliedDaylight = -1.0
    local function applyDaylight()
        local ambient <const> = app.renderer.deferred.ambient
        mixColor(ambient, 0.015, 0.02, 0.035, 0.085, 0.10, 0.13, daylight)

        local shadow <const> = meshes.shadow
        shadow.directionX = mix(0.35, -0.42, daylight)
        shadow.directionY = -1.0
        shadow.directionZ = mix(0.18, -0.26, daylight)
        shadow.r = mix(0.45, 1.0, daylight)
        shadow.g = mix(0.58, 0.88, daylight)
        shadow.b = mix(1.0, 0.72, daylight)
        shadow.intensity = mix(0.15, 2.5, daylight)

        local probe <const> = meshes.probe
        mixColor(probe.positiveX, 0.035, 0.045, 0.065, 0.20, 0.18, 0.16, daylight)
        mixColor(probe.negativeX, 0.025, 0.035, 0.055, 0.12, 0.15, 0.20, daylight)
        mixColor(probe.positiveY, 0.075, 0.095, 0.14, 0.35, 0.42, 0.58, daylight)
        mixColor(probe.negativeY, 0.008, 0.006, 0.01, 0.055, 0.045, 0.04, daylight)
        mixColor(probe.positiveZ, 0.045, 0.035, 0.03, 0.24, 0.19, 0.15, daylight)
        mixColor(probe.negativeZ, 0.025, 0.035, 0.055, 0.13, 0.17, 0.24, daylight)
        probe.intensity = mix(2.0, 3.0, daylight)

        local fog <const> = meshes.fog
        fog.start = mix(65, 100, daylight)
        fog.finish = mix(150, 220, daylight)
        fog.r = mix(0.025, 0.35, daylight)
        fog.g = mix(0.04, 0.42, daylight)
        fog.b = mix(0.08, 0.55, daylight)

        for _, entity in ipairs(lampEntities) do
            local light <const> = world:getMut(entity, PointLight3D)
            light.radius = mix(14, 9, daylight)
            light.intensity = mix(10, 1.5, daylight)
        end
        appliedDaylight = daylight
    end

    world:addSystem({
        name = "example.BistroDayNight",
        phase = tecs.ecs.phases.Update,
        run = function()
            local wheel <const> = app.input.wheelY
            if wheel ~= 0.0 then
                daylight = math.max(0.0, math.min(1.0, daylight + wheel * DAYLIGHT_PER_WHEEL))
            end
            if daylight ~= appliedDaylight then
                applyDaylight()
                if wheel ~= 0.0 then
                    print(("bistro3d: daylight %d%%"):format(math.floor(daylight * 100 + 0.5)))
                end
            end
        end,
    })

    local loaded <const> = tecs.assets.loadGLTF(tecs.io.files.assetPath("external/bistro/Bistro.tecs.gltf"))
    local instance <const> = meshes:registerModel(loaded):newInstance()
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
            #instance.primitives, meshes.vertexCount, meshes.indexCount, meshes.materialCount, meshes.textureCount
        )
    )
    print("bistro3d: click to look; WASD moves, Q/E changes height, Shift sprints, Tab releases")
    print("bistro3d: mouse wheel blends continuously between night and day")
end

return tecs.newApplication({
    window = {title = "Tecs Bistro stress scene", width = 1280, height = 720},
    ambientLight = {0.043, 0.052, 0.073},
    sprites = false,
    bloom = {scale = 0.25, threshold = 0.4, knee = 0.25, intensity = 1.3},
    meshes = {
        capacity = 1600,
        vertexCapacity = 3100000,
        indexCapacity = 8600000,
        materialCapacity = 160,
        textureWidth = 512,
        textureHeight = 512,
        textureLayers = 280,
        packTextures = false,
        mipmaps = true,
        textureFormat = tecs.assets.IMAGE_BC3,
        lights = {capacity = 4},
        probe = {
            positiveX = {0.10, 0.115, 0.14},
            negativeX = {0.075, 0.085, 0.11},
            positiveY = {0.24, 0.30, 0.42},
            negativeY = {0.035, 0.025, 0.022},
            positiveZ = {0.13, 0.105, 0.09},
            negativeZ = {0.07, 0.085, 0.12},
            intensity = 2.4,
        },
        fog = {start = 80, finish = 180, r = 0.18, g = 0.22, b = 0.30},
        shadows = {
            scale = 0.5,
            distance = 60,
            directionX = -0.42,
            directionY = -1,
            directionZ = -0.26,
            r = 1.0,
            g = 0.86,
            b = 0.68,
            intensity = 2.1,
            strength = 0.68,
            softness = 1.0,
        },
    },
    maxEntities = 1700,
    framesInFlight = 2,
    fixedMaxSteps = 240,
    presentMode = os.getenv("TECS_PRESENT") or "immediate",
    debug = true,
    showFps = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
