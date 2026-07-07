--- Bucket-aware cull dispatch + per-(tier, array) output buffers for
--- the renderer-owned shadow sprite path. Parallels the simpler
--- `text/shadow_dispatch.tl` and `gpu/shadow_dispatch.tl` modules but
--- routes per archetype into the bucket that archetype belongs to.
---
--- A "bucket" is a (tierIdx, arrayIdx) pair. The sprite system already
--- groups archetypes by these axes for texture-array compatibility:
--- tier picks the size class (Tiny → XXL), arrayIdx picks which atlas
--- texture-array within that tier. Each bucket has its own output
--- buffer set so the renderer can issue one draw call per bucket
--- against the right texture array.
---
--- Buckets are created lazily as archetypes appear in them. Per-bucket
--- buffers grow when the bucket's live entity count exceeds capacity.
---
--- The cull shader and per-archetype dispatch logic itself is shader-
--- specific; this module owns the buffer ownership and dispatch shell.

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local blend <const> = require("tecs2d.gfx.internal.blend")
local TextureArray <const> = require("tecs2d.gfx.internal.sprite.TextureArray")

local Transform <const> = tecs.builtins.Transform

local lg <const> = love.graphics
local ceil <const> = math.ceil
local bor <const> = require("bit").bor
local C <const> = require("ffi")

local record shadow_dispatch
    record OptionalBinding
        component: tecs.Component
        layout: std430.Descriptor
        mask: integer
        ssboName: string
    end

    --- Per-archetype tag-to-flag binding. When the archetype has the
    --- tag component, `flag` is OR'd into the dispatch's `StaticFlags`
    --- uniform. Used for zero-data tags like `Unlit`.
    record TagFlagBinding
        component: tecs.Component
        flag: integer
    end

    record BucketBuffers
        --- Per-instance visible sprite output (cull writes via atomicAdd).
        outputBuffer: love.graphics.Buffer
        --- Occluder dual-write target for the shadow pass.
        shadowOutputBuffer: love.graphics.Buffer
        --- Drop-shadow per-light fan-out target.
        dropShadowOutputBuffer: love.graphics.Buffer
        --- Per-instance material params, indexed alongside outputBuffer.
        --- Field name matches `bucket_sync`'s `arraySync.materialParams
        --- OutputBuffer` so callers can reuse arraySync as the bucket
        --- via `bucketProvider` during the slot-path migration.
        materialParamsOutputBuffer: love.graphics.Buffer
        --- Indirect args for the main draw (4 uint32: vertCount,
        --- instCount, firstVert, firstInst).
        indirectBuffer: love.graphics.Buffer
        shadowIndirectBuffer: love.graphics.Buffer
        dropShadowIndirectBuffer: love.graphics.Buffer
        --- Row capacity for output / shadow / materialParams.
        capacity: integer
        --- Drop-shadow capacity scales differently (per-light fan-out
        --- can multiply per-entity output by N affecting lights).
        dropShadowCapacity: integer
    end

    record Config
        --- The compute cull shader. Pass `nil` to set up buffer
        --- ownership without enabling dispatch (useful while the
        --- shader is being authored).
        shader: love.graphics.ComputeShader
        registry: archetype_registry.Registry
        spriteComponent: tecs.Component
        bucketMarkers: {tecs.Component}
        optional: {OptionalBinding}
        --- Tag-to-flag bindings (see TagFlagBinding). Defaults to none.
        tagFlags: {TagFlagBinding}
        --- Initial per-bucket capacity. Buckets grow on demand.
        initialBucketCapacity: integer
        --- Initial drop-shadow capacity per bucket. Worst case is
        --- entities × max-affecting-lights, so size accordingly.
        initialDropShadowCapacity: integer
        --- Optional callback returning the bucket's buffers given
        --- (tierIdx, arrayIdx). When set, the dispatch routes outputs
        --- to caller-owned buffers (e.g. `bucket_sync`'s arraySync)
        --- instead of allocating its own. Used during the slot-path
        --- retirement to avoid double-buffering.
        bucketProvider: function(tierIdx: integer, arrayIdx: integer): BucketBuffers
        --- Optional per-frame setup. Called once before the archetype
        --- loop; the caller binds frame-global SSBOs and uniforms
        --- (GlobalTime, FrameTimings, lights, etc.) the cull shader
        --- needs. The dispatch keeps `CullParams` / `ArchetypeRowCount`
        --- / `ComponentMask` / `BlendId` itself.
        bindGlobals: function(shader: love.graphics.ComputeShader, renderer: any, cullParamsBuffer: love.graphics.Buffer)
        --- Optional per-archetype setup. Called per dispatched archetype
        --- after the standard inputs are bound, so callers can attach
        --- per-bucket SSBOs like the texture array's slice-generations
        --- buffer.
        bindPerArchetype: function(shader: love.graphics.ComputeShader, tierIdx: integer, arrayIdx: integer)
    end

    record Context
        --- Lookup or lazy-create a bucket's buffers.
        getBucket: function(self: Context, tierIdx: integer, arrayIdx: integer): BucketBuffers
        --- Enumerate live buckets (those with at least one allocation).
        --- Render plugin uses this to issue per-bucket draws.
        liveBuckets: function(self: Context): function(): integer, integer, BucketBuffers
        --- Fire the cull dispatch. No-op if `shader` is nil.
        dispatch: function(self: Context, renderer: any, cullParamsBuffer: love.graphics.Buffer)
    end

    new: function(config: Config): Context
end

-- ---------------------------------------------------------------------------
-- Dummy SSBO singletons. Used when an archetype lacks an optional
-- component; the shader's `ComponentMask` branches the read but a
-- valid SSBO binding is still required.
-- ---------------------------------------------------------------------------

local dummyByFormat: {string: love.graphics.Buffer} = {}

local function dummyFor(layout: std430.Descriptor): love.graphics.Buffer
    local existing = dummyByFormat[layout.shadowCtype]
    if existing then return existing end
    local buf = lg.newBuffer(layout.format, 1, {usage = "static", shaderstorage = true})
    dummyByFormat[layout.shadowCtype] = buf
    return buf
end

-- ---------------------------------------------------------------------------
-- Indirect args reset data. Standard 4-uint32 indirect layout
-- {vertexCount=6, instanceCount=0, firstVertex=0, firstInstance=0}.
-- The cull shader atomicAdd's into instanceCount.
-- ---------------------------------------------------------------------------

local indirectResetData: love.data.ByteData = nil

local function getIndirectResetData(): love.data.ByteData
    if indirectResetData then return indirectResetData end
    indirectResetData = love.data.newByteData(16)
    local ptr = C.cast("uint32_t*", indirectResetData:getFFIPointer()) as {integer: integer}
    ptr[0] = 6  -- vertex count
    ptr[1] = 0  -- instance count (atomic)
    ptr[2] = 0  -- first vertex
    ptr[3] = 0  -- first instance
    return indirectResetData
end

local function newBucket(initialCapacity: integer, initialDropShadowCapacity: integer): shadow_dispatch.BucketBuffers
    local resetData = getIndirectResetData()

    local function newIndirect(): love.graphics.Buffer
        local b = lg.newBuffer({{format = "uint32"}}, 4,
            {usage = "dynamic", shaderstorage = true, indirectarguments = true})
        b:setArrayData(resetData)
        return b
    end

    return {
        outputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, initialCapacity,
            {usage = "dynamic", shaderstorage = true}),
        shadowOutputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, initialCapacity,
            {usage = "dynamic", shaderstorage = true}),
        dropShadowOutputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, initialDropShadowCapacity,
            {usage = "dynamic", shaderstorage = true}),
        materialParamsOutputBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, initialCapacity,
            {usage = "dynamic", shaderstorage = true}),
        indirectBuffer = newIndirect(),
        shadowIndirectBuffer = newIndirect(),
        dropShadowIndirectBuffer = newIndirect(),
        capacity = initialCapacity,
        dropShadowCapacity = initialDropShadowCapacity,
    }
end

local function ensureBucketCapacity(bucket: shadow_dispatch.BucketBuffers, entityCount: integer, dropShadowCount: integer)
    if entityCount > bucket.capacity then
        local newCap = bucket.capacity * 2
        if newCap < entityCount then newCap = entityCount end
        bucket.outputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, newCap,
            {usage = "dynamic", shaderstorage = true})
        bucket.shadowOutputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, newCap,
            {usage = "dynamic", shaderstorage = true})
        bucket.materialParamsOutputBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, newCap,
            {usage = "dynamic", shaderstorage = true})
        bucket.capacity = newCap
    end
    if dropShadowCount > bucket.dropShadowCapacity then
        local newCap = bucket.dropShadowCapacity * 2
        if newCap < dropShadowCount then newCap = dropShadowCount end
        bucket.dropShadowOutputBuffer = lg.newBuffer(gpuTypes.SPRITE_FORMAT, newCap,
            {usage = "dynamic", shaderstorage = true})
        bucket.dropShadowCapacity = newCap
    end
end

function shadow_dispatch.new(config: shadow_dispatch.Config): shadow_dispatch.Context
    local shader <const> = config.shader
    local registry <const> = config.registry
    local spriteComponent <const> = config.spriteComponent
    local bucketMarkers <const> = config.bucketMarkers
    local optional <const> = config.optional
    local tagFlags <const> = config.tagFlags
    local tagFlagCount <const> = tagFlags and #tagFlags or 0
    local initialCap <const> = config.initialBucketCapacity
    local initialDsCap <const> = config.initialDropShadowCapacity
    local bucketProvider <const> = config.bucketProvider
    local bindGlobals <const> = config.bindGlobals
    local bindPerArchetype <const> = config.bindPerArchetype

    -- Two-level table: buckets[tierIdx][arrayIdx] = BucketBuffers.
    -- Keyed by integer indices so per-frame iteration over live
    -- entries is straightforward (and stable while archetypes exist).
    local buckets: {integer: {integer: shadow_dispatch.BucketBuffers}} = {}

    -- Per-archetype cached bucket lookup. Sprite archetypes don't
    -- change tier/array assignments after creation (bucket markers are
    -- assigned once), so caching is safe.
    local archBucketCache: {tecs.Archetype: {integer: integer}} = {}

    -- Resolve which (tier, array) bucket an archetype belongs to.
    -- Returns nil if the archetype isn't bucketed (shouldn't happen
    -- for archetypes the registry tracks, but defend against it).
    local function resolveBucket(arch: tecs.Archetype): integer, integer
        local cached = archBucketCache[arch]
        if cached then
            return cached[1], cached[2]
        end

        local tierIdx = 0
        for i = 1, #bucketMarkers do
            if arch.columns[bucketMarkers[i]] ~= nil then
                tierIdx = i
                break
            end
        end
        if tierIdx == 0 then return 0, 0 end

        local arrayIdx = TextureArray.getArrayIndex(arch)
        if arrayIdx == 0 then return 0, 0 end

        archBucketCache[arch] = {tierIdx, arrayIdx}
        return tierIdx, arrayIdx
    end

    local function getBucket(_self: shadow_dispatch.Context, tierIdx: integer, arrayIdx: integer): shadow_dispatch.BucketBuffers
        if bucketProvider then
            return bucketProvider(tierIdx, arrayIdx)
        end
        local tier = buckets[tierIdx]
        if not tier then
            tier = {}
            buckets[tierIdx] = tier
        end
        local b = tier[arrayIdx]
        if not b then
            b = newBucket(initialCap, initialDsCap)
            tier[arrayIdx] = b
        end
        return b
    end

    local function liveBuckets(_self: shadow_dispatch.Context): function(): integer, integer, shadow_dispatch.BucketBuffers
        local tierKeys: {integer} = {}
        for k in pairs(buckets) do tierKeys[#tierKeys + 1] = k end
        local ti = 0
        local arrayKeys: {integer} = {}
        local ai = 0
        local currentTier = 0
        return function(): integer, integer, shadow_dispatch.BucketBuffers
            while true do
                if ai < #arrayKeys then
                    ai = ai + 1
                    local arrayIdx = arrayKeys[ai]
                    return currentTier, arrayIdx, buckets[currentTier][arrayIdx]
                end
                ti = ti + 1
                if ti > #tierKeys then return nil, nil, nil end
                currentTier = tierKeys[ti]
                arrayKeys = {}
                for k in pairs(buckets[currentTier]) do
                    arrayKeys[#arrayKeys + 1] = k
                end
                ai = 0
            end
        end
    end

    local resetData = getIndirectResetData()

    local function dispatch(self: shadow_dispatch.Context, renderer: any, cullParamsBuffer: love.graphics.Buffer)
        if shader == nil then return end

        if bindGlobals then
            bindGlobals(shader, renderer, cullParamsBuffer)
        end

        -- Reset all live buckets' indirect counters. Buckets that no
        -- longer have entities still get reset; the draw call will
        -- short-circuit on instanceCount=0.
        for _tierIdx, _arrayIdx, b in self:liveBuckets() do
            b.indirectBuffer:setArrayData(resetData)
            b.shadowIndirectBuffer:setArrayData(resetData)
            b.dropShadowIndirectBuffer:setArrayData(resetData)
        end

        for arch, stateAny in registry:archetypes() do
            local state = stateAny as shadow_state.ArchetypeState
            if state.destroyed then goto continue end

            local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
            if rowCount == 0 then goto continue end

            local tierIdx, arrayIdx = resolveBucket(arch)
            if tierIdx == 0 then goto continue end

            -- Grow this bucket if the live entity count exceeds its
            -- output capacity. Drop-shadow capacity is harder to
            -- predict per-entity (depends on affecting lights), so
            -- grow on a coarser bound: rowCount * MAX_AFFECTING_LIGHTS
            -- approximation. Tighten once profiles tell us where this
            -- runs out.
            local bucket = getBucket(self, tierIdx, arrayIdx)
            -- Caller-owned buffers (provider path) manage their own
            -- capacity via slot allocations. Only grow when we own
            -- the buffers ourselves.
            if not bucketProvider then
                ensureBucketCapacity(bucket, rowCount, rowCount * 8)
            end

            local shadows = state.shadows

            local transformBuf = shadows:get(Transform)
            if not transformBuf then goto continue end
            shader:send("TransformInput", (transformBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

            local spriteBuf = shadows:get(spriteComponent)
            if not spriteBuf then goto continue end
            shader:send("SpriteInput", (spriteBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

            local mask = 0
            for i = 1, #optional do
                local b = optional[i]
                local mb = shadows:get(b.component)
                if mb then
                    shader:send(b.ssboName, (mb as {string:any}).gpuBuffer as love.graphics.Buffer)
                    mask = bor(mask, b.mask)
                else
                    shader:send(b.ssboName, dummyFor(b.layout))
                end
            end

            local staticFlags = 0
            for i = 1, tagFlagCount do
                local tf = tagFlags[i]
                if arch.columns[tf.component] ~= nil then
                    staticFlags = bor(staticFlags, tf.flag)
                end
            end

            shader:send("CullParams", cullParamsBuffer)
            shader:send("ArchetypeRowCount", rowCount)
            shader:send("ComponentMask", mask)
            shader:send("BlendId", blend.groupBy(arch))
            if (shader as {string:any}).hasUniform and shader:hasUniform("StaticFlags") then
                shader:send("StaticFlags", staticFlags)
            end

            if bindPerArchetype then
                bindPerArchetype(shader, tierIdx, arrayIdx)
            end

            -- Per-bucket output bindings. Different from circles/text
            -- where outputs are global; here each (tier, array) bucket
            -- has its own buffer so the renderer can draw one bucket
            -- per draw call against the right texture array.
            shader:send("SpriteOutput", bucket.outputBuffer)
            shader:send("SpriteShadowOutput", bucket.shadowOutputBuffer)
            shader:send("DropShadowOutput", bucket.dropShadowOutputBuffer)
            if shader:hasUniform("MaxDropShadows") then
                -- The per-light fan-out's write guard. Must be this
                -- bucket's actual buffer capacity or the atomicAdd
                -- index runs past the SSBO.
                shader:send("MaxDropShadows", bucket.dropShadowCapacity or bucket.capacity)
            end
            shader:send("MaterialParamsOutput", bucket.materialParamsOutputBuffer)
            shader:send("IndirectArgs", bucket.indirectBuffer)
            shader:send("ShadowIndirectArgs", bucket.shadowIndirectBuffer)
            shader:send("DropShadowIndirectArgs", bucket.dropShadowIndirectBuffer)

            lg.dispatchThreadgroups(shader, ceil(rowCount / 256), 1, 1)

            ::continue::
        end
    end

    return {
        getBucket = getBucket,
        liveBuckets = liveBuckets,
        dispatch = dispatch,
    }
end

return shadow_dispatch
