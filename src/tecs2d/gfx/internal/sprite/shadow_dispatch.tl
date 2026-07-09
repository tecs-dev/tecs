--- Bucket-aware cull dispatch for the sprite shadow path. Parallels
--- the simpler `text/shadow_dispatch.tl` and `gpu/shadow_dispatch.tl`
--- modules but routes per archetype into the bucket that archetype
--- belongs to.
---
--- A "bucket" is a (tierIdx, arrayIdx) pair. The sprite system already
--- groups archetypes by these axes for texture-array compatibility:
--- tier picks the size class (Tiny → XXL), arrayIdx picks which atlas
--- texture-array within that tier. Each bucket has its own output
--- buffer set so the renderer can issue one draw call per bucket
--- against the right texture array.
---
--- Bucket buffers are owned by the caller (`bucket_sync`'s arraySyncs,
--- handed in via `bucketProvider`); this module owns the dispatch shell.

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local blend <const> = require("tecs2d.gfx.internal.blend")
local TextureArray <const> = require("tecs2d.gfx.internal.sprite.TextureArray")
local dummyFor <const> = require("tecs2d.gfx.internal.gpu.dummy_ssbo").dummyFor

local Transform <const> = tecs.builtins.Transform

local lg <const> = love.graphics
local ceil <const> = math.ceil
local bor <const> = require("bit").bor

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

    --- The buffer set `bucketProvider` returns for a bucket. Field
    --- names match `bucket_sync`'s ArraySync so an arraySync can be
    --- returned directly.
    record BucketBuffers
        --- Per-instance visible sprite output (cull writes via atomicAdd).
        outputBuffer: love.graphics.Buffer
        --- Occluder dual-write target for the shadow pass.
        shadowOutputBuffer: love.graphics.Buffer
        --- Drop-shadow per-light fan-out target.
        dropShadowOutputBuffer: love.graphics.Buffer
        --- Per-instance material params, indexed alongside outputBuffer.
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
        --- Returns the bucket's buffers given (tierIdx, arrayIdx), or
        --- nil when the bucket doesn't exist; archetypes resolving to a
        --- nil bucket are skipped. The caller owns the buffers and
        --- their capacity (`bucket_sync`'s arraySync); the caller also
        --- resets the indirect counters each frame (render_plugin's
        --- resetIndirect).
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
        --- Fire the cull dispatch. No-op if `shader` is nil.
        dispatch: function(self: Context, renderer: any, cullParamsBuffer: love.graphics.Buffer)
    end

    new: function(config: Config): Context
end

function shadow_dispatch.new(config: shadow_dispatch.Config): shadow_dispatch.Context
    local shader <const> = config.shader
    local registry <const> = config.registry
    local spriteComponent <const> = config.spriteComponent
    local bucketMarkers <const> = config.bucketMarkers
    local optional <const> = config.optional
    local tagFlags <const> = config.tagFlags
    local tagFlagCount <const> = tagFlags and #tagFlags or 0
    local bucketProvider <const> = config.bucketProvider
    local bindGlobals <const> = config.bindGlobals
    local bindPerArchetype <const> = config.bindPerArchetype

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
        local cols = (arch as tecsInternal.ArchetypeInternal).columns
        for i = 1, #bucketMarkers do
            if cols[bucketMarkers[i]] ~= nil then
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

    local function dispatch(_self: shadow_dispatch.Context, renderer: any, cullParamsBuffer: love.graphics.Buffer)
        if shader == nil then return end

        if bindGlobals then
            bindGlobals(shader, renderer, cullParamsBuffer)
        end

        for arch, stateAny in registry:archetypes() do
            local state = stateAny as shadow_state.ArchetypeState
            if state.destroyed then goto continue end

            local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
            if rowCount == 0 then goto continue end

            local tierIdx, arrayIdx = resolveBucket(arch)
            if tierIdx == 0 then goto continue end

            -- Buffers and capacity are owned by the provider
            -- (bucket_sync's arraySync, grown by its lifecycle
            -- observer); a nil bucket means the archetype's bucket
            -- hasn't been created yet, so skip it this frame.
            local bucket = bucketProvider(tierIdx, arrayIdx)
            if bucket == nil then goto continue end

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
            local cols = (arch as tecsInternal.ArchetypeInternal).columns
            for i = 1, tagFlagCount do
                local tf = tagFlags[i]
                if cols[tf.component] ~= nil then
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
        dispatch = dispatch,
    }
end

return shadow_dispatch
