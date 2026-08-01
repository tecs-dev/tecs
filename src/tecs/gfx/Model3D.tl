--[=[
Resident glTF models and allocation-stable node animation.

`renderer.meshes:registerModel` consumes decoded CPU assets and returns a
`Model3D`. Each `newInstance` owns its joint palettes, morph weights, and
primitive templates, so copies of one model can play different poses without
duplicating geometry, materials, textures, morph deltas, or clips.

```teal
local model <const> = app.renderer.meshes:registerModel(loaded.value)
local instance <const> = model:newInstance()
for index, primitive in ipairs(instance.primitives) do
    local entity <const> = world:spawn(
        primitive.transform,
        primitive.mesh,
        primitive.bounds,
        primitive.material,
        primitive.skin,
        primitive.morph,
        tecs.gfx.Tint(1, 1, 1, 1),
        tecs.gfx.Renderable3D()
    )
    instance:bind(world, index, entity)
end
instance:play("Walk")

world:addSystem({
    name = "game.AnimateModel",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        instance:update(dt)
    end,
})
```

Sampling resets the reusable pose to the file's base TRS, applies one clip,
builds node world matrices in parent order, updates bound `Transform3D`
components, and stages each instance-owned skin palette and morph vector. No
table or cdata is allocated per sample. Bounds remain caller-owned and must
enclose every pose.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local type modeltypes = require("tecs.internal.render.modeltypes")

local Transform3D <const> = ecs.Transform3D

local type World = types.World

--- Contains the component bundle for one model primitive instance.
local record Primitive
    --- Caller-writable. Contains the sampled world transform.
    transform: ecs.Transform3D
    --- Caller-writable. Selects resident geometry.
    mesh: components.Mesh
    --- Caller-writable. Supplies the local bound, which must enclose every
    --- animated pose.
    bounds: components.Bounds3D
    --- Caller-writable. Selects resident PBR material data.
    material: components.MeshMaterial
    --- Caller-writable. Selects this instance's joint palette, or nil for
    --- rigid geometry.
    skin: components.MeshSkin
    --- Caller-writable. Selects this instance's morph weights, or nil for
    --- geometry without morph targets.
    morph: components.MeshMorph
end

--- Configures `Instance:play`.
local record PlayOptions
    --- Caller-writable. Multiplies elapsed time and defaults to one. Negative
    --- values raise.
    speed: number
    --- Caller-writable. Restarts after the clip duration and defaults to true.
    loop: boolean
    --- Caller-writable. Starts advancing immediately and defaults to true.
    playing: boolean
end

local interface ModelOwner
    --- Read-only. Contains the source asset path.
    path: string
    --- Read-only. Contains decoded clips in file order.
    animations: {assets.ModelAnimation}
    --- Read-only. Reports the number of decoded clips.
    animationCount: integer

    --- Returns a clip's one-based index.
    --- @param name The caller supplies an authored or generated clip name.
    --- @return Returns its index, or nil when absent. Duplicate authored names
    ---     raise because selecting either by that name would be ambiguous.
    animationIndex: function(self, name: string): integer
    _domain: modeltypes.Domain
    _registration: string
    _draws: {assets.ModelDraw}
    _nodes: {assets.ModelNode}
    _skins: {assets.ModelSkin}
    _meshes: {components.Mesh}
    _bounds: {components.Bounds3D}
    _materials: {components.MeshMaterial}
    _order: {integer}
    _animationByName: {string: integer}
    _nextInstance: integer
end

--- Plays one independently posed copy of a resident model.
local record Instance
    --- Read-only. Contains this instance's spawnable primitive bundles.
    primitives: {Primitive}
    --- Read-only. Reports the selected one-based clip, or zero before `play`.
    animation: integer
    --- Read-only. Reports the current clip time in seconds.
    time: number
    --- Caller-writable. Multiplies elapsed time. Negative values raise on
    --- `update`.
    speed: number
    --- Caller-writable. Controls whether playback wraps at the duration.
    loop: boolean
    --- Caller-writable. Controls whether `update` advances playback.
    playing: boolean

    --- Binds one primitive to an existing entity's `Transform3D`.
    --- @param world The caller supplies the entity's world. Every binding on
    ---     one instance must use the same world.
    --- @param primitive The caller supplies a one-based primitive index.
    --- @param entity The caller supplies a live entity carrying `Transform3D`.
    bind: function(self, world: World, primitive: integer, entity: integer)

    --- Removes one primitive's entity binding.
    --- @param primitive The caller supplies a one-based primitive index.
    unbind: function(self, primitive: integer)

    --- Selects and restarts a clip.
    --- @param animation The caller supplies a one-based index or clip name.
    --- @param options Omitted fields default to speed one, looping, and
    ---     immediate playback.
    play: function(self, animation: string | integer, options?: PlayOptions)

    --- Samples a clip at an explicit time without allocating.
    --- @param animation The caller supplies a one-based index or clip name.
    --- @param time The caller supplies seconds. Negative values clamp to zero.
    --- @param loop Whether time wraps at the duration. Defaults to false.
    sample: function(self, animation: string | integer, time: number, loop?: boolean)

    --- Advances and samples the selected clip.
    --- @param dt The caller supplies non-negative elapsed seconds.
    update: function(self, dt: number)

    _model: ModelOwner
    _world: World
    _entities: {integer: integer}
    _pose: {number}
    _localMatrices: {number}
    _worldMatrices: {number}
    _palettes: {{number}}
    _skins: {components.MeshSkin}
    _morphs: {components.MeshMorph}
    _morphWeights: {{number}}
    _temporary: {number}
    _inverse: {number}
end

local record Model3D is ModelOwner
    type Primitive = Primitive
    type Instance = Instance
    type PlayOptions = PlayOptions

    --- Creates an independently animated instance.
    --- @return Returns reusable primitive templates plus private joint
    ---     palettes and morph-weight vectors.
    newInstance: function(self): Instance
end

local Model3DMT <const>: metatable<Model3D> = {__index = Model3D}
local InstanceMT <const>: metatable<Instance> = {__index = Instance}

local function multiply(a: {number}, ao: integer, b: {number}, bo: integer, out: {number}, oo: integer)
    for column = 0, 3 do
        for row = 0, 3 do
            local sum = 0.0
            for lane = 0, 3 do
                sum = sum + a[ao + lane * 4 + row] * b[bo + column * 4 + lane]
            end
            out[oo + column * 4 + row] = sum
        end
    end
end

local function compose(pose: {number}, po: integer, out: {number}, offset: integer)
    local x, y, z, w <const> = pose[po + 3], pose[po + 4], pose[po + 5], pose[po + 6]
    local sx, sy, sz <const> = pose[po + 7], pose[po + 8], pose[po + 9]
    local xx, yy, zz <const> = x * x, y * y, z * z
    local xy, xz, yz <const> = x * y, x * z, y * z
    local wx, wy, wz <const> = w * x, w * y, w * z
    out[offset] = (1 - 2 * (yy + zz)) * sx
    out[offset + 1] = (2 * (xy + wz)) * sx
    out[offset + 2] = (2 * (xz - wy)) * sx
    out[offset + 3] = 0
    out[offset + 4] = (2 * (xy - wz)) * sy
    out[offset + 5] = (1 - 2 * (xx + zz)) * sy
    out[offset + 6] = (2 * (yz + wx)) * sy
    out[offset + 7] = 0
    out[offset + 8] = (2 * (xz + wy)) * sz
    out[offset + 9] = (2 * (yz - wx)) * sz
    out[offset + 10] = (1 - 2 * (xx + yy)) * sz
    out[offset + 11] = 0
    out[offset + 12], out[offset + 13], out[offset + 14], out[offset + 15] = pose[po], pose[po + 1], pose[po + 2], 1
end

local function inverseAffine(source: {number}, offset: integer, out: {number})
    local a00, a01, a02 <const> = source[offset], source[offset + 4], source[offset + 8]
    local a10, a11, a12 <const> = source[offset + 1], source[offset + 5], source[offset + 9]
    local a20, a21, a22 <const> = source[offset + 2], source[offset + 6], source[offset + 10]
    local determinant <const> = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (
        a10 * a21 - a11 * a20
    )
    if math.abs(determinant) <= 1e-20 then
        error("tecs: an animated mesh transform is not invertible", 3)
    end
    local d <const> = 1.0 / determinant
    local i00, i01, i02 <const> = (a11 * a22 - a12 * a21) * d, (a02 * a21 - a01 * a22) * d, (a01 * a12 - a02 * a11) * d
    local i10, i11, i12 <const> = (a12 * a20 - a10 * a22) * d, (a00 * a22 - a02 * a20) * d, (a02 * a10 - a00 * a12) * d
    local i20, i21, i22 <const> = (a10 * a21 - a11 * a20) * d, (a01 * a20 - a00 * a21) * d, (a00 * a11 - a01 * a10) * d
    local tx, ty, tz <const> = source[offset + 12], source[offset + 13], source[offset + 14]
    out[1], out[2], out[3], out[4] = i00, i10, i20, 0
    out[5], out[6], out[7], out[8] = i01, i11, i21, 0
    out[9], out[10], out[11], out[12] = i02, i12, i22, 0
    out[13] = -(i00 * tx + i01 * ty + i02 * tz)
    out[14] = -(i10 * tx + i11 * ty + i12 * tz)
    out[15], out[16] = -(i20 * tx + i21 * ty + i22 * tz), 1
end

local function writeTransform(matrix: {number}, offset: integer, target: ecs.Transform3D)
    local sx = math.sqrt(matrix[offset] ^ 2 + matrix[offset + 1] ^ 2 + matrix[offset + 2] ^ 2)
    local sy <const> = math.sqrt(matrix[offset + 4] ^ 2 + matrix[offset + 5] ^ 2 + matrix[offset + 6] ^ 2)
    local sz <const> = math.sqrt(matrix[offset + 8] ^ 2 + matrix[offset + 9] ^ 2 + matrix[offset + 10] ^ 2)
    local determinant <const> = matrix[offset] * (
        matrix[offset + 5] * matrix[offset + 10] - matrix[offset + 6] * matrix[offset + 9]
    ) - matrix[offset + 4] * (
        matrix[offset + 1] * matrix[offset + 10] - matrix[offset + 2] * matrix[offset + 9]
    ) + matrix[offset + 8] * (matrix[offset + 1] * matrix[offset + 6] - matrix[offset + 2] * matrix[offset + 5])
    if sx <= 1e-20 or sy <= 1e-20 or sz <= 1e-20 then
        error("tecs: an animated node has a zero scale axis", 3)
    end
    if determinant < 0 then
        sx = -sx
    end
    local r00, r01, r02 <const> = matrix[offset] / sx, matrix[offset + 4] / sy, matrix[offset + 8] / sz
    local r10, r11, r12 <const> = matrix[offset + 1] / sx, matrix[offset + 5] / sy, matrix[offset + 9] / sz
    local r20, r21, r22 <const> = matrix[offset + 2] / sx, matrix[offset + 6] / sy, matrix[offset + 10] / sz
    if
        math.abs(r00 * r01 + r10 * r11 + r20 * r21) > 1e-4
        or math.abs(r00 * r02 + r10 * r12 + r20 * r22) > 1e-4
        or math.abs(r01 * r02 + r11 * r12 + r21 * r22) > 1e-4
    then
        error("tecs: an animated node hierarchy produces shear", 3)
    end
    local qx, qy, qz, qw = 0.0, 0.0, 0.0, 1.0
    local trace <const> = r00 + r11 + r22
    if trace > 0 then
        local scale <const> = math.sqrt(trace + 1.0) * 2
        qw, qx, qy, qz = 0.25 * scale, (r21 - r12) / scale, (r02 - r20) / scale, (r10 - r01) / scale
    elseif r00 > r11 and r00 > r22 then
        local scale <const> = math.sqrt(1.0 + r00 - r11 - r22) * 2
        qw, qx, qy, qz = (r21 - r12) / scale, 0.25 * scale, (r01 + r10) / scale, (r02 + r20) / scale
    elseif r11 > r22 then
        local scale <const> = math.sqrt(1.0 + r11 - r00 - r22) * 2
        qw, qx, qy, qz = (r02 - r20) / scale, (r01 + r10) / scale, 0.25 * scale, (r12 + r21) / scale
    else
        local scale <const> = math.sqrt(1.0 + r22 - r00 - r11) * 2
        qw, qx, qy, qz = (r10 - r01) / scale, (r02 + r20) / scale, (r12 + r21) / scale, 0.25 * scale
    end
    target.x, target.y, target.z = matrix[offset + 12], matrix[offset + 13], matrix[offset + 14]
    target.rotationX, target.rotationY, target.rotationZ, target.rotationW = qx, qy, qz, qw
    target.scaleX, target.scaleY, target.scaleZ = sx, sy, sz
end

local function findKey(times: {number}, time: number): integer
    if time <= times[1] then
        return 1
    end
    local last <const> = #times
    if time >= times[last] then
        return last
    end
    local low, high = 1, last - 1
    while low <= high do
        local middle <const> = math.floor((low + high) * 0.5)
        if time < times[middle] then
            high = middle - 1
        elseif time >= times[middle + 1] then
            low = middle + 1
        else
            return middle
        end
    end
    return math.max(1, math.min(last, low))
end

local function normalizeRotation(pose: {number}, offset: integer)
    local length <const> = math.sqrt(
        pose[offset] ^ 2 + pose[offset + 1] ^ 2 + pose[offset + 2] ^ 2 + pose[offset + 3] ^ 2
    )
    if length <= 1e-20 then
        error("tecs: an animation produced a zero rotation quaternion", 3)
    end
    pose[offset], pose[offset + 1], pose[offset + 2], pose[offset + 3] = pose[offset] / length,
        pose[offset + 1] / length,
        pose[offset + 2] / length,
        pose[offset + 3] / length
end

local function sampleChannel(
    channel: assets.ModelAnimationChannel, time: number, target: {number}, targetOffset: integer
)
    local width <const> = channel.width
    local times <const> = channel.times
    local values <const> = channel.values
    local key <const> = findKey(times, time)
    local last <const> = #times
    if channel.interpolation == assets.ANIMATION_STEP or key == last or time <= times[1] then
        local row <const> = channel.interpolation == assets.ANIMATION_CUBIC and ((key - 1) * 3 + 1) or key - 1
        local source <const> = row * width
        for lane = 0, width - 1 do
            target[targetOffset + lane] = values[source + lane + 1]
        end
    elseif channel.interpolation == assets.ANIMATION_CUBIC then
        local span <const> = times[key + 1] - times[key]
        local alpha <const> = (time - times[key]) / span
        local alpha2, alpha3 <const> = alpha * alpha, alpha * alpha * alpha
        local h00, h10 <const> = 2 * alpha3 - 3 * alpha2 + 1, alpha3 - 2 * alpha2 + alpha
        local h01, h11 <const> = -2 * alpha3 + 3 * alpha2, alpha3 - alpha2
        local left <const> = (key - 1) * 3 * width
        local right <const> = key * 3 * width
        for lane = 0, width - 1 do
            local p0 <const> = values[left + width + lane + 1]
            local m0 <const> = values[left + width * 2 + lane + 1] * span
            local p1 <const> = values[right + width + lane + 1]
            local m1 <const> = values[right + lane + 1] * span
            target[targetOffset + lane] = h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
        end
    elseif channel.path == assets.ANIMATION_ROTATION then
        local left <const> = (key - 1) * 4
        local right <const> = key * 4
        local dot = 0.0
        for lane = 1, 4 do
            dot = dot + values[left + lane] * values[right + lane]
        end
        local sign = 1.0
        if dot < 0 then
            dot, sign = -dot, -1.0
        end
        dot = math.max(-1.0, math.min(1.0, dot))
        local alpha <const> = (time - times[key]) / (times[key + 1] - times[key])
        local a, b = 1.0 - alpha, alpha
        if dot < 0.9995 then
            local angle <const> = math.acos(dot)
            local inverse <const> = 1.0 / math.sin(angle)
            a, b = math.sin((1.0 - alpha) * angle) * inverse, math.sin(alpha * angle) * inverse
        end
        for lane = 0, 3 do
            target[targetOffset + lane] = values[left + lane + 1] * a + values[right + lane + 1] * sign * b
        end
    else
        local alpha <const> = (time - times[key]) / (times[key + 1] - times[key])
        local left <const> = (key - 1) * width
        local right <const> = key * width
        for lane = 0, width - 1 do
            local a, b <const> = values[left + lane + 1], values[right + lane + 1]
            target[targetOffset + lane] = a + (b - a) * alpha
        end
    end
    if channel.path == assets.ANIMATION_ROTATION then
        normalizeRotation(target, targetOffset)
    end
end

local function animationIndex(model: ModelOwner, animation: string | integer): integer
    if type(animation) == "number" then
        local index <const> = animation as integer
        if index < 1 or index > model.animationCount or index ~= math.floor(index) then
            error(
                ("tecs: model animation index %s is outside 1..%d"):format(tostring(animation), model.animationCount), 3
            )
        end
        return index
    end
    local index <const> = model:animationIndex(animation as string)
    if index == nil then
        error(("tecs: model '%s' has no animation '%s'"):format(model.path, tostring(animation)), 3)
    end
    return index
end

local function evaluate(self: Instance, animation: integer, time: number)
    local model <const> = self._model
    local pose <const> = self._pose
    for index, node in ipairs(model._nodes) do
        local offset <const> = (index - 1) * 10
        pose[offset + 1], pose[offset + 2], pose[offset + 3] = node.x, node.y, node.z
        pose[offset + 4], pose[offset + 5], pose[offset + 6], pose[offset + 7] = node.rotationX,
            node.rotationY,
            node.rotationZ,
            node.rotationW
        pose[offset + 8], pose[offset + 9], pose[offset + 10] = node.scaleX, node.scaleY, node.scaleZ
    end
    for index = 1, #model._draws do
        local weights = self._morphWeights[index]
        if weights ~= nil then
            local defaults <const> = model._draws[index].weights
            for target, weight in ipairs(defaults) do
                weights[target] = weight
            end
        end
    end
    if animation ~= 0 then
        for _, channel in ipairs(model.animations[animation].channels) do
            if channel.path == assets.ANIMATION_WEIGHTS then
                for index, draw in ipairs(model._draws) do
                    local weights = self._morphWeights[index]
                    if draw.node == channel.node and weights ~= nil then
                        sampleChannel(channel, time, weights, 1)
                    end
                end
            else
                local offset <const> = (channel.node - 1) * 10 + (
                    channel.path == assets.ANIMATION_TRANSLATION and 1
                    or channel.path == assets.ANIMATION_ROTATION and 4
                    or 8
                )
                sampleChannel(channel, time, pose, offset)
            end
        end
    end
    local locals <const> = self._localMatrices
    for index, node in ipairs(model._nodes) do
        local offset <const> = (index - 1) * 16 + 1
        if node.matrix ~= nil then
            for lane = 0, 15 do
                locals[offset + lane] = node.matrix[lane + 1]
            end
        else
            compose(pose, (index - 1) * 10 + 1, locals, offset)
        end
    end
    local worlds <const> = self._worldMatrices
    for _, nodeIndex in ipairs(model._order) do
        local node <const> = model._nodes[nodeIndex]
        local offset <const> = (nodeIndex - 1) * 16 + 1
        if node.parent == 0 then
            for lane = 0, 15 do
                worlds[offset + lane] = locals[offset + lane]
            end
        else
            multiply(worlds, (node.parent - 1) * 16 + 1, locals, offset, worlds, offset)
        end
    end
    for index, draw in ipairs(model._draws) do
        local primitive <const> = self.primitives[index]
        writeTransform(worlds, (draw.node - 1) * 16 + 1, primitive.transform)
        local entity <const> = self._entities[index]
        if entity ~= nil then
            local target <const> = self._world:getMut(entity, Transform3D)
            local source <const> = primitive.transform
            target.x, target.y, target.z = source.x, source.y, source.z
            target.rotationX, target.rotationY, target.rotationZ, target.rotationW = source.rotationX,
                source.rotationY,
                source.rotationZ,
                source.rotationW
            target.scaleX, target.scaleY, target.scaleZ = source.scaleX, source.scaleY, source.scaleZ
        end
    end
    for index, source in ipairs(model._skins) do
        local palette <const> = self._palettes[index]
        inverseAffine(worlds, (source.node - 1) * 16 + 1, self._inverse)
        for jointIndex, node in ipairs(source.joints) do
            local bindOffset <const> = (jointIndex - 1) * 16 + 1
            multiply(worlds, (node - 1) * 16 + 1, source.inverseBindMatrices, bindOffset, self._temporary, 1)
            multiply(self._inverse, 1, self._temporary, 1, palette, bindOffset)
        end
        model._domain:updateSkin(self._skins[index], palette)
    end
    for index = 1, #model._draws do
        local weights = self._morphWeights[index]
        if weights ~= nil then
            model._domain:updateMorph(self._morphs[index], weights)
        end
    end
end

function Model3D:animationIndex(name: string): integer
    if name == nil or name == "" then
        error("tecs: a model animation name cannot be empty", 2)
    end
    local index <const> = self._animationByName[name]
    if index == 0 then
        error(("tecs: model '%s' has more than one animation named '%s'"):format(self.path, name), 2)
    end
    return index
end

function Model3D:newInstance(): Instance
    self._nextInstance = self._nextInstance + 1
    local skins: {components.MeshSkin} = {}
    local palettes: {{number}} = {}
    for index, source in ipairs(self._skins) do
        local palette: {number} = {}
        for lane, value in ipairs(source.matrices) do
            palette[lane] = value
        end
        palettes[index] = palette
        skins[index] = self._domain:registerSkin(
            self._registration .. "#instance-" .. self._nextInstance .. "-skin-" .. index, palette
        )
    end
    local primitives: {Primitive} = {}
    local morphs: {components.MeshMorph} = {}
    local morphWeights: {{number}} = {}
    for index, draw in ipairs(self._draws) do
        if #draw.weights > 0 then
            local weights: {number} = {}
            for target, weight in ipairs(draw.weights) do
                weights[target] = weight
            end
            morphWeights[index] = weights
            morphs[index] = self._domain:registerMorph(
                self._registration .. "#instance-" .. self._nextInstance .. "-morph-" .. index, weights
            )
        end
        primitives[index] = {
            transform = Transform3D(),
            mesh = self._meshes[draw.mesh],
            bounds = self._bounds[draw.mesh],
            material = self._materials[draw.material] or components.MeshMaterial(),
            skin = skins[draw.skin],
            morph = morphs[index],
        }
    end
    local instance <const> = setmetatable(
        {
            primitives = primitives,
            animation = 0,
            time = 0.0,
            speed = 1.0,
            loop = true,
            playing = false,
            _model = self,
            _entities = {},
            _pose = {},
            _localMatrices = {},
            _worldMatrices = {},
            _palettes = palettes,
            _skins = skins,
            _morphs = morphs,
            _morphWeights = morphWeights,
            _temporary = {},
            _inverse = {},
        } as Instance,
        InstanceMT
    )
    evaluate(instance, 0, 0.0)
    return instance
end

function Instance:bind(world: World, primitive: integer, entity: integer)
    if world == nil then
        error("tecs: a model binding needs a world", 2)
    end
    if self.primitives[primitive] == nil then
        error(("tecs: model primitive %s is outside 1..%d"):format(tostring(primitive), #self.primitives), 2)
    end
    if self._world ~= nil and self._world ~= world then
        error("tecs: one model instance cannot bind entities from different worlds", 2)
    end
    local target <const> = world:getMut(entity, Transform3D)
    local source <const> = self.primitives[primitive].transform
    target.x, target.y, target.z = source.x, source.y, source.z
    target.rotationX, target.rotationY, target.rotationZ, target.rotationW = source.rotationX,
        source.rotationY,
        source.rotationZ,
        source.rotationW
    target.scaleX, target.scaleY, target.scaleZ = source.scaleX, source.scaleY, source.scaleZ
    self._world = world
    self._entities[primitive] = entity
end

function Instance:unbind(primitive: integer)
    if self.primitives[primitive] == nil then
        error(("tecs: model primitive %s is outside 1..%d"):format(tostring(primitive), #self.primitives), 2)
    end
    self._entities[primitive] = nil
end

function Instance:play(animation: string | integer, options?: PlayOptions)
    options = options or {} as PlayOptions
    local speed <const> = options.speed or 1.0
    if speed < 0 then
        error("tecs: model animation speed cannot be negative", 2)
    end
    self.animation = animationIndex(self._model, animation)
    self.time = 0.0
    self.speed = speed
    self.loop = options.loop == nil or options.loop
    self.playing = options.playing == nil or options.playing
    evaluate(self, self.animation, 0.0)
end

function Instance:sample(animation: string | integer, time: number, loop?: boolean)
    if time == nil or time ~= time or time == math.huge or time == -math.huge then
        error("tecs: model animation time must be finite", 2)
    end
    local index <const> = animationIndex(self._model, animation)
    local duration <const> = self._model.animations[index].duration
    local sampled = math.max(0.0, time)
    if loop and duration > 0 then
        sampled = sampled % duration
    else
        sampled = math.min(sampled, duration)
    end
    self.animation, self.time = index, sampled
    evaluate(self, index, sampled)
end

function Instance:update(dt: number)
    if dt == nil or dt ~= dt or dt < 0 or dt == math.huge then
        error("tecs: model animation delta must be finite and non-negative", 2)
    end
    if not self.playing or self.animation == 0 then
        return
    end
    if self.speed < 0 or self.speed ~= self.speed or self.speed == math.huge then
        error("tecs: model animation speed must be finite and non-negative", 2)
    end
    local duration <const> = self._model.animations[self.animation].duration
    local time = self.time + dt * self.speed
    if self.loop and duration > 0 then
        time = time % duration
    elseif time >= duration then
        time = duration
        self.playing = false
    end
    self.time = time
    evaluate(self, self.animation, time)
end

local function orderOf(nodes: {assets.ModelNode}): {integer}
    local order: {integer} = {}
    local state: {integer: integer} = {}
    local function visit(index: integer)
        if state[index] == 2 then
            return
        end
        if state[index] == 1 then
            error("tecs: a model node hierarchy contains a cycle", 3)
        end
        state[index] = 1
        local parent <const> = nodes[index].parent
        if parent ~= 0 then
            if nodes[parent] == nil then
                error("tecs: a model node names a missing parent", 3)
            end
            visit(parent)
        end
        state[index] = 2
        order[#order + 1] = index
    end
    for index = 1, #nodes do
        visit(index)
    end
    return order
end

--- Creates the resident model wrapper used by `MeshDomain`.
--- @param domain The mesh domain that owns palette residency.
--- @param registration A unique stable prefix for per-instance palettes.
--- @param source The decoded model whose Lua scene data remains live.
--- @param meshes Resident geometry components by decoded mesh index.
--- @param bounds Resident bounds by decoded mesh index.
--- @param materials Resident materials by decoded material index.
--- @return Returns a model ready to create independent instances.
function Model3D._create(
    domain: modeltypes.Domain,
    registration: string,
    source: assets.Model,
    meshes: {components.Mesh},
    bounds: {components.Bounds3D},
    materials: {components.MeshMaterial}
): Model3D
    local byName: {string: integer} = {}
    for index, animation in ipairs(source.animations) do
        local existing <const> = byName[animation.name]
        byName[animation.name] = existing ~= nil and 0 or index
    end
    return setmetatable(
        {
            path = source.path,
            animations = source.animations,
            animationCount = #source.animations,
            _domain = domain,
            _registration = registration,
            _draws = source.draws,
            _nodes = source.nodes,
            _skins = source.skins,
            _meshes = meshes,
            _bounds = bounds,
            _materials = materials,
            _order = orderOf(source.nodes),
            _animationByName = byName,
            _nextInstance = 0,
        } as Model3D,
        Model3DMT
    )
end

return Model3D
