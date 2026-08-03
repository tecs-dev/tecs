--- Loads the pinned Amazon Lumberyard Bistro exterior with an ambient probe.

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

local INITIAL_DAYLIGHT <const> = 0.55
local DAYLIGHT_PER_WHEEL <const> = 0.08
local INITIAL_CAMERA_X <const> = 9.1325
local INITIAL_CAMERA_Y <const> = 2.6832
local INITIAL_CAMERA_Z <const> = -26.1308
local SHADOWED_FIXTURES <const> = 4

local record FixtureProfile
    spot: boolean
    r: number
    g: number
    b: number
end

local record FixtureLight
    x: number
    y: number
    z: number
    rotationX: number
    rotationY: number
    rotationZ: number
    rotationW: number
    distanceSquared: number
    profile: FixtureProfile
end

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

local function tuneLegacyMaterial(material: tecs.assets.ModelMaterial)
    -- The source marks every material as a non-PBR Phong conversion and gives
    -- concrete, foliage, glass, and metal the same metallic and roughness
    -- factors. Classify its authored names so view-dependent highlights stay
    -- on surfaces that plausibly have them instead of sweeping over the whole
    -- street as the camera moves.
    local name <const> = material.name:lower()
    if
        name:find("metal", 1, true)
        or name:find("bronze", 1, true)
        or name:find("steel", 1, true)
        or name:find("iron", 1, true)
        or name:find("chain", 1, true)
        or name:find("manhole", 1, true)
    then
        material.metallic = 0.7
        material.roughness = 0.48
    elseif name:find("glass", 1, true) or name:find("wet", 1, true) then
        material.metallic = 0.0
        material.roughness = 0.5
    else
        material.metallic = 0.0
        material.roughness = 0.75
    end
end

local function fixtureProfile(name: string): FixtureProfile
    if name:find("Emissive_StreetLight", 1, true) or name:find("Spotlight_Glass_Emissive", 1, true) then
        return {spot = true, r = 1.0, g = 0.62, b = 0.25}
    end
    if not name:find("Paris_StringLights_01_", 1, true) or not name:find("_Emissive", 1, true) then
        return nil
    end
    if name:find("Blue", 1, true) then
        return {spot = false, r = 0.28, g = 0.48, b = 1.0}
    elseif name:find("Pink", 1, true) then
        return {spot = false, r = 1.0, g = 0.28, b = 0.52}
    elseif name:find("Red", 1, true) then
        return {spot = false, r = 1.0, g = 0.18, b = 0.12}
    elseif name:find("Green", 1, true) then
        return {spot = false, r = 0.2, g = 1.0, b = 0.32}
    elseif name:find("Orange", 1, true) then
        return {spot = false, r = 1.0, g = 0.42, b = 0.12}
    end
    return {spot = false, r = 1.0, g = 0.78, b = 0.48}
end

local function fixturePosition(draw: tecs.assets.ModelDraw, mesh: tecs.assets.Mesh): number, number, number
    local x <const> = mesh.centerX * draw.scaleX
    local y <const> = mesh.centerY * draw.scaleY
    local z <const> = mesh.centerZ * draw.scaleZ
    local qx, qy, qz, qw <const> = draw.rotationX, draw.rotationY, draw.rotationZ, draw.rotationW
    local tx <const> = 2.0 * (qy * z - qz * y)
    local ty <const> = 2.0 * (qz * x - qx * z)
    local tz <const> = 2.0 * (qx * y - qy * x)
    return draw.x + x + qw * tx + qy * tz - qz * ty,
        draw.y + y + qw * ty + qz * tx - qx * tz,
        draw.z + z + qw * tz + qx * ty - qy * tx
end

local function findFixtureLights(model: tecs.assets.Model): {FixtureLight}
    local fixtures: {FixtureLight} = {}
    for _, draw in ipairs(model.draws) do
        local material <const> = model.materials[draw.material]
        local profile <const> = material ~= nil and fixtureProfile(material.name) or nil
        if profile ~= nil then
            local x, y, z <const> = fixturePosition(draw, model.meshes[draw.mesh])
            local duplicate = false
            for _, fixture in ipairs(fixtures) do
                local dx <const>, dy <const>, dz <const> = fixture.x - x, fixture.y - y, fixture.z - z
                if dx * dx + dy * dy + dz * dz < 0.25 then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                local dx <const>, dy <const>, dz <const> = x - INITIAL_CAMERA_X,
                    y - INITIAL_CAMERA_Y,
                    z - INITIAL_CAMERA_Z
                fixtures[#fixtures + 1] = {
                    x = x,
                    y = y,
                    z = z,
                    rotationX = draw.rotationX,
                    rotationY = draw.rotationY,
                    rotationZ = draw.rotationZ,
                    rotationW = draw.rotationW,
                    distanceSquared = dx * dx + dy * dy + dz * dz,
                    profile = profile,
                }
            end
        end
    end
    table.sort(
        fixtures, function(a: FixtureLight, b: FixtureLight): boolean return a.distanceSquared < b.distanceSquared end
    )
    return fixtures
end

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    local camera <const> = meshes.camera

    -- Use the authored exterior camera. Its quaternion turns Tecs' negative-Z
    -- camera forward toward the street's positive-Z extent.
    camera.x = INITIAL_CAMERA_X
    camera.y = INITIAL_CAMERA_Y
    camera.z = INITIAL_CAMERA_Z
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

    local pointLampEntities: {integer} = {}
    local spotLampEntities: {integer} = {}

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

        for _, entity in ipairs(pointLampEntities) do
            local light <const> = world:getMut(entity, PointLight3D)
            light.radius = mix(8, 5, daylight)
            light.intensity = mix(5, 0.2, daylight)
        end
        for _, entity in ipairs(spotLampEntities) do
            local light <const> = world:getMut(entity, SpotLight3D)
            light.radius = mix(16, 10, daylight)
            light.intensity = mix(20, 1.0, daylight)
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
    for _, material in ipairs(loaded.materials) do
        tuneLegacyMaterial(material)
    end
    local shadowed = 0
    local fixtures <const> = findFixtureLights(loaded)
    for _, fixture in ipairs(fixtures) do
        local profile <const> = fixture.profile
        if profile.spot then
            local qx, qy, qz, qw <const> = fixture.rotationX, fixture.rotationY, fixture.rotationZ, fixture.rotationW
            local directionX <const> = -2.0 * (qw * qy + qz * qx)
            local directionY <const> = 2.0 * (qw * qx - qz * qy)
            local directionZ <const> = -1.0 + 2.0 * (qx * qx + qy * qy)
            local flags = 0
            if shadowed < SHADOWED_FIXTURES then
                flags = tecs.gfx.LIGHT_CASTS_SHADOWS
                shadowed = shadowed + 1
            end
            spotLampEntities[#spotLampEntities + 1] = world:spawn(
                Transform3D.new({
                    -- Move just beyond the emissive glass so the fixture does
                    -- not shadow its own complete cone.
                    x = fixture.x + directionX * 0.2,
                    y = fixture.y + directionY * 0.2,
                    z = fixture.z + directionZ * 0.2,
                    rotationX = qx,
                    rotationY = qy,
                    rotationZ = qz,
                    rotationW = qw,
                }),
                SpotLight3D.new({
                    radius = 16,
                    innerAngle = math.rad(48),
                    outerAngle = math.rad(72),
                    r = profile.r,
                    g = profile.g,
                    b = profile.b,
                    intensity = 20,
                    flags = flags,
                })
            )
        else
            pointLampEntities[#pointLampEntities + 1] = world:spawn(
                Transform3D.new({x = fixture.x, y = fixture.y, z = fixture.z}),
                PointLight3D(8, profile.r, profile.g, profile.b, 5)
            )
        end
    end
    local instance <const> = meshes:registerModel(loaded):newInstance()
    for _, primitive in ipairs(instance.primitives) do
        world:spawn(
            primitive.transform, primitive.mesh, primitive.bounds, primitive.material, Tint(1, 1, 1, 1), Renderable3D()
        )
    end
    print(
        ("bistro3d: loaded %d GPU-cullable chunks, %d vertices, %d indices, %d materials, and %d textures"):format(
            #instance.primitives, meshes.vertexCount, meshes.indexCount, meshes.materialCount, meshes.textureCount
        )
    )
    print(
        ("bistro3d: attached %d local lights to emissive fixtures; %d nearby spotlights cast shadows"):format(
            #fixtures, shadowed
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
        lights = {
            capacity = 128,
            shadows = {capacity = SHADOWED_FIXTURES, size = 256, bias = 0.003, softness = 1},
        },
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
    maxEntities = 1824,
    framesInFlight = 2,
    fixedMaxSteps = 240,
    presentMode = os.getenv("TECS_PRESENT") or "immediate",
    debug = true,
    showFps = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
