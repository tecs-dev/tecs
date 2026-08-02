local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ecs = require("tecs.ecs")
local assets = require("tecs.assets")
local components = require("tecs.components")
local Model3D = require("tecs.gfx.Model3D")

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

local function copy(values)
    local answer = {}
    for index, value in ipairs(values) do
        answer[index] = value
    end
    return answer
end

local function source(channels)
    return {
        path = "spec://animated-model",
        animations = {
            {
                name = "Move",
                duration = 1,
                channels = channels,
            },
        },
        nodes = {
            {
                parent = 0,
                x = 0,
                y = 0,
                z = 0,
                rotationX = 0,
                rotationY = 0,
                rotationZ = 0,
                rotationW = 1,
                scaleX = 1,
                scaleY = 1,
                scaleZ = 1,
            },
            {
                parent = 1,
                x = 0,
                y = 0,
                z = 0,
                rotationX = 0,
                rotationY = 0,
                rotationZ = 0,
                rotationW = 1,
                scaleX = 1,
                scaleY = 1,
                scaleZ = 1,
            },
        },
        skins = {
            {
                name = "spec://skin",
                matrices = copy(IDENTITY),
                node = 1,
                joints = { 2 },
                inverseBindMatrices = copy(IDENTITY),
            },
        },
        draws = {
            {
                mesh = 1,
                material = 0,
                skin = 1,
                node = 1,
                weights = {},
            },
        },
    }
end

local function domain()
    local nextSlot = 0
    local updates = {}
    local morphUpdates = {}
    local value = {}
    function value:registerSkin(name, matrices)
        local skin = components.MeshSkin(components.meshSkinId(name), nextSlot)
        nextSlot = nextSlot + #matrices / 16
        updates[skin.asset] = matrices
        return skin
    end
    function value:updateSkin(skin, matrices)
        updates[skin.asset] = matrices
    end
    function value:registerMorph(name, weights)
        local morph = components.MeshMorph(components.meshMorphId(name), nextSlot)
        nextSlot = nextSlot + #weights
        morphUpdates[morph.asset] = copy(weights)
        return morph
    end
    function value:updateMorph(morph, weights)
        morphUpdates[morph.asset] = copy(weights)
    end
    return value, updates, morphUpdates
end

local function registered(channels)
    local owner, updates, morphUpdates = domain()
    local model = Model3D._create(
        owner,
        "spec://animated-model#residency-1",
        source(channels),
        { components.Mesh(1, 0) },
        { components.Bounds3D(0, 0, 0, 4) },
        {}
    )
    return model, updates, morphUpdates
end

describe("Model3D", function()
    it("samples independent node transforms and joint palettes", function()
        local model, updates = registered({
            {
                node = 1,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 0, 0, 0, 1, 0 },
            },
            {
                node = 2,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 0, 0, 1, 0, 0 },
            },
        })
        local first = model:newInstance()
        local second = model:newInstance()

        first:sample("Move", 0.25)
        second:sample(1, 0.75)

        assert.near(0.25, first.primitives[1].transform.y, 1e-6)
        assert.near(0.75, second.primitives[1].transform.y, 1e-6)
        assert.near(0.25, updates[first.primitives[1].skin.asset][13], 1e-6)
        assert.near(0, updates[first.primitives[1].skin.asset][14], 1e-6)
        assert.near(0.75, updates[second.primitives[1].skin.asset][13], 1e-6)
        assert.are_not.equal(first.primitives[1].skin.asset, second.primitives[1].skin.asset)
    end)

    it("updates bound entity transforms and non-looping playback", function()
        local model = registered({
            {
                node = 1,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_STEP,
                times = { 0, 1 },
                values = { 0, 0, 0, 0, 2, 0 },
            },
        })
        local instance = model:newInstance()
        local world = ecs.newWorld()
        local entity = world:spawn(ecs.Transform3D())
        world:enqueueCommit()
        instance:bind(world, 1, entity)
        instance:play("Move", { loop = false })

        instance:update(1)

        assert.near(2, world:get(entity, ecs.Transform3D).y, 1e-6)
        assert.is_false(instance.playing)
        assert.near(1, instance.time, 1e-6)
    end)

    it("uses shortest-path quaternion slerp", function()
        local half = math.sqrt(0.5)
        local model = registered({
            {
                node = 1,
                path = assets.ANIMATION_ROTATION,
                width = 4,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 0, 0, 1, 0, 0, 1, 0 },
            },
        })
        local instance = model:newInstance()

        instance:sample("Move", 0.5)

        assert.near(half, math.abs(instance.primitives[1].transform.rotationZ), 1e-6)
        assert.near(half, math.abs(instance.primitives[1].transform.rotationW), 1e-6)
    end)

    it("composes caller placement after the animated hierarchy", function()
        local model = registered({
            {
                node = 1,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 0, 0, 1, 0, 0 },
            },
        })
        local instance = model:newInstance()
        local placement = ecs.Transform3D(3, 4, 5)
        placement.rotationY = 1
        placement.rotationW = 0
        instance.transform = placement

        instance:sample("Move", 1)

        assert.near(2, instance.primitives[1].transform.x, 1e-6)
        assert.near(4, instance.primitives[1].transform.y, 1e-6)
        assert.near(5, instance.primitives[1].transform.z, 1e-6)
        assert.near(1, math.abs(instance.primitives[1].transform.rotationY), 1e-6)
        assert.near(0, instance.primitives[1].transform.rotationW, 1e-6)
    end)

    it("samples cubic-spline values without allocating a new pose", function()
        local model = registered({
            {
                node = 1,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_CUBIC,
                times = { 0, 1 },
                values = {
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                    0,
                    1,
                    0,
                    0,
                    1,
                    0,
                    0,
                    0,
                    0,
                    0,
                },
            },
        })
        local instance = model:newInstance()
        local pose = instance._pose

        instance:sample("Move", 0.5)

        assert.are.equal(pose, instance._pose)
        assert.near(0.5, instance.primitives[1].transform.x, 1e-6)
    end)

    it("samples morph weights independently from transforms and skins", function()
        local model, _, morphUpdates = registered({
            {
                node = 1,
                path = assets.ANIMATION_WEIGHTS,
                width = 1,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 1 },
            },
        })
        model._draws[1].weights = { 0 }
        local first = model:newInstance()
        local second = model:newInstance()

        first:sample("Move", 0.25)
        second:sample("Move", 0.75)

        assert.near(0.25, morphUpdates[first.primitives[1].morph.asset][1], 1e-6)
        assert.near(0.75, morphUpdates[second.primitives[1].morph.asset][1], 1e-6)
        assert.are_not.equal(first.primitives[1].morph.asset, second.primitives[1].morph.asset)
        assert.near(0, first.primitives[1].transform.x, 1e-6)
    end)

    it("rejects ambiguous names and invalid playback values", function()
        local model = registered({
            {
                node = 1,
                path = assets.ANIMATION_TRANSLATION,
                width = 3,
                interpolation = assets.ANIMATION_LINEAR,
                times = { 0, 1 },
                values = { 0, 0, 0, 1, 0, 0 },
            },
        })
        model.animations[2] = model.animations[1]
        model.animationCount = 2
        model._animationByName.Move = 0
        local instance = model:newInstance()

        assert.has_error(function()
            instance:play("Move")
        end, "tecs: model 'spec://animated-model' has more than one animation named 'Move'")
        assert.has_error(function()
            instance:update(-1)
        end, "tecs: model animation delta must be finite and non-negative")
    end)
end)
