--- Cull dispatch + output buffers for the renderer-owned shadow text
--- path. Parallels `gpu/shadow_dispatch.tl` for circles but binds two
--- output buffers (per-entity header + per-glyph visible-glyph entries)
--- where the generic shadow_dispatch only models one.
---
--- Indirect args layout (single shared buffer):
---   args[0] = vertex count (host-set, 6 for two triangles)
---   args[1] = instance count (atomic; total visible glyphs -- drives the draw)
---   args[2] = first vertex   (constant 0)
---   args[3] = first instance (constant 0)
---   args[4] = entity count   (atomic; total visible entities -- header out)
---
--- The cull shader's `args[1]` and `args[4]` atomicAdd writes match
--- this layout. `args[0]/[2]/[3]` are written once at construction.
---
--- Output buffers grow when the live row total across text archetypes
--- exceeds the current capacity. The header buffer scales by visible-
--- entity count; the glyph buffer scales by visible-glyph count
--- (worst case = sum of charCount across all live entities).

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local blend <const> = require("tecs2d.gfx.internal.blend")
local dummyFor <const> = require("tecs2d.gfx.internal.gpu.dummy_ssbo").dummyFor
local C <const> = require("ffi")

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

    record Buffers
        --- Per-entity packed render header (TEXT_HEADER_FORMAT). One
        --- entry per visible text entity. Indexed by `headerIndex` from
        --- visibleGlyphBuffer.
        headerBuffer: love.graphics.Buffer
        --- Per-glyph instance entry { headerIndex, glyphIndex }. One
        --- entry per visible glyph; gl_InstanceID indexes this buffer.
        visibleGlyphBuffer: love.graphics.Buffer
        --- Per-entity material params, parallel to headerBuffer.
        materialParamsBuffer: love.graphics.Buffer
        --- Shared indirect args (see header comment for layout).
        indirectBuffer: love.graphics.Buffer
    end

    record Config
        shader: love.graphics.ComputeShader
        registry: archetype_registry.Registry
        textComponent: tecs.Component
        optional: {OptionalBinding}
        --- Tag-to-flag bindings (see TagFlagBinding). Defaults to none.
        tagFlags: {TagFlagBinding}
        buffers: Buffers
        --- Initial entity / glyph capacities. Used to seed the header
        --- and visible-glyph buffers; both grow on demand via the
        --- ensureCapacity hook returned alongside the dispatch.
        initialEntityCapacity: integer
        initialGlyphCapacity: integer
    end

    new: function(config: Config): function(any, love.graphics.Buffer), function(integer, integer)

    --- Construct the four buffers in one call. Initial capacities seed
    --- the buffers; the ensureCapacity hook returned by `new` handles
    --- subsequent grows.
    newBuffers: function(initialEntityCapacity: integer, initialGlyphCapacity: integer): Buffers
end

-- Reset-data ByteData built once and reused. setArrayData wants a
-- ByteData (or buffer-typed source); a Lua table doesn't satisfy the
-- LÖVE 12 binding signature.
local INDIRECT_ARG_COUNT <const> = 8
local indirectResetData: love.data.ByteData = nil

local function getIndirectResetData(): love.data.ByteData
    if indirectResetData then return indirectResetData end
    indirectResetData = love.data.newByteData(INDIRECT_ARG_COUNT * 4)
    local ptr = C.cast("uint32_t*", indirectResetData:getFFIPointer()) as {integer: integer}
    ptr[0] = 6     -- args[0]: vertex count
    ptr[1] = 0     -- args[1]: instance count (atomic; glyph total)
    ptr[2] = 0     -- args[2]: first vertex
    ptr[3] = 0     -- args[3]: first instance
    ptr[4] = 0     -- args[4]: entity count (atomic; header out)
    ptr[5] = 0
    ptr[6] = 0
    ptr[7] = 0
    return indirectResetData
end

function shadow_dispatch.newBuffers(
    initialEntityCapacity: integer,
    initialGlyphCapacity: integer
): shadow_dispatch.Buffers
    if initialEntityCapacity < 1 then initialEntityCapacity = 1 end
    if initialGlyphCapacity < 1 then initialGlyphCapacity = 1 end

    local indirectBuffer = lg.newBuffer({{format = "uint32"}}, INDIRECT_ARG_COUNT,
        {usage = "dynamic", shaderstorage = true, indirectarguments = true})
    -- Seed the indirect args' constant fields. args[1] and args[4] are
    -- atomic counters; the host resets them to 0 each frame before the
    -- dispatch.
    indirectBuffer:setArrayData(getIndirectResetData())

    return {
        headerBuffer = lg.newBuffer(gpuTypes.TEXT_HEADER_FORMAT, initialEntityCapacity,
            {usage = "dynamic", shaderstorage = true}),
        visibleGlyphBuffer = lg.newBuffer(gpuTypes.VISIBLE_GLYPH_FORMAT, initialGlyphCapacity,
            {usage = "dynamic", shaderstorage = true}),
        materialParamsBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, initialEntityCapacity,
            {usage = "dynamic", shaderstorage = true}),
        indirectBuffer = indirectBuffer,
    }
end

function shadow_dispatch.new(config: shadow_dispatch.Config): function(any, love.graphics.Buffer), function(integer, integer)
    local shader <const> = config.shader
    local registry <const> = config.registry
    local textComponent <const> = config.textComponent
    local optional <const> = config.optional
    local tagFlags <const> = config.tagFlags
    local tagFlagCount <const> = tagFlags and #tagFlags or 0
    local buffers = config.buffers
    local entityCapacity = config.initialEntityCapacity
    local glyphCapacity = config.initialGlyphCapacity

    local function ensureCapacity(entityCount: integer, glyphCount: integer)
        if entityCount > entityCapacity then
            local newCap = entityCapacity * 2
            if newCap < entityCount then newCap = entityCount end
            buffers.headerBuffer = lg.newBuffer(gpuTypes.TEXT_HEADER_FORMAT, newCap,
                {usage = "dynamic", shaderstorage = true})
            buffers.materialParamsBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, newCap,
                {usage = "dynamic", shaderstorage = true})
            entityCapacity = newCap
        end
        if glyphCount > glyphCapacity then
            local newCap = glyphCapacity * 2
            if newCap < glyphCount then newCap = glyphCount end
            buffers.visibleGlyphBuffer = lg.newBuffer(gpuTypes.VISIBLE_GLYPH_FORMAT, newCap,
                {usage = "dynamic", shaderstorage = true})
            glyphCapacity = newCap
        end
    end

    local resetData = getIndirectResetData()
    local dispatch = function(_renderer: any, cullParamsBuffer: love.graphics.Buffer)
        -- Reset the atomic counters. args[0]/[2]/[3] stay at their
        -- seeded values (6, 0, 0). args[1] = visible glyph count and
        -- args[4] = visible entity count are zeroed each frame.
        buffers.indirectBuffer:setArrayData(resetData)

        for arch, stateAny in registry:archetypes() do
            local state = stateAny as shadow_state.ArchetypeState
            if state.destroyed then goto continue end

            local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
            if rowCount == 0 then goto continue end

            local shadows = state.shadows

            local transformBuf = shadows:get(Transform)
            if not transformBuf then goto continue end
            shader:send("TransformInput", (transformBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

            local textBuf = shadows:get(textComponent)
            if not textBuf then goto continue end
            shader:send("TextInput", (textBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

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

            shader:send("TextHeaderOutput", buffers.headerBuffer)
            shader:send("VisibleGlyphOutput", buffers.visibleGlyphBuffer)
            shader:send("MaterialParamsOutput", buffers.materialParamsBuffer)
            shader:send("IndirectArgs", buffers.indirectBuffer)

            lg.dispatchThreadgroups(shader, ceil(rowCount / 256), 1, 1)

            ::continue::
        end
    end

    return dispatch, ensureCapacity
end

return shadow_dispatch
