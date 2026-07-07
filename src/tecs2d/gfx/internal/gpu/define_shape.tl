--- Declarative shape registration over the shadow-column path.
---
--- `shadow_plugin.register` is the full, explicit descriptor: ~45 lines
--- per shape, most of it mechanical. `defineShape` derives all of that
--- so a shape declares only what is genuinely shape-specific:
---
---   - the primary component + its render/cull (+ optional shadow) shaders
---   - which modifier components it supports (a bare handle list)
---   - which tag components it honours (a bare handle list)
---   - the alpha-blend filter flag
---
--- Everything else is derived:
---   - all naming strings              ← `name` (+ optional `prefix`)
---   - each modifier's layout/SSBO/mask ← `modifier_binding` (shared)
---   - each tag's static flag           ← `modifier_binding` (shared)
---   - output + stub buffer formats     ← `gpuTypes.<PREFIX>_*`
---
--- A shape has two naming roots that usually coincide: `name` is the
--- primary component's `componentName` (drives the std430 layout, the
--- input SSBO, the system/registry labels, the material name). `prefix`
--- is the GPU-constant / output-buffer root (drives `gpuTypes.<PREFIX>_*`
--- and the `<Prefix>Output` names) and defaults to `name`. They differ
--- only when the GPU constants were named differently from the component
--- (e.g. component "Rectangle" but constants "RECT_*").

local tecs <const> = require("tecs")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shadow_plugin <const> = require("tecs2d.gfx.internal.gpu.shadow_plugin")
local modifier_binding <const> = require("tecs2d.gfx.internal.gpu.modifier_binding")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")

local lg <const> = love.graphics

-- The culled-instance *output* format and the (vestigial) stub formats
-- are larger structs declared by the shape's render/cull GLSL. They
-- follow the `gpuTypes.<PREFIX>_*` naming convention, so derive by name.
local gtByName <const> = gpuTypes as {string: any}

local record define_shape
    record Config
        --- Primary component name, e.g. "Circle" / "Rectangle". Equals
        --- the primary component's `componentName`; drives the std430
        --- layout, input SSBO name, and system/registry labels.
        name: string
        --- The primary shape component (Circle / Rectangle / ...).
        component: tecs.Component
        --- Compiled render + cull shaders.
        render: love.graphics.Shader
        cull: love.graphics.ComputeShader
        --- Optional shadow-mask shader. Presence enables the shadow pass.
        shadowMask: love.graphics.Shader
        --- Modifier components this shape supports. Each must have an entry
        --- in `modifier_binding.MASK` matching the shape's cull GLSL.
        modifiers: {tecs.Component}
        --- Tag components this shape honours (each via the shared TAG_FLAG).
        tags: {tecs.Component}
        --- Forwarded to the descriptor's alpha-blend filter flag.
        alphaBlendFilter: boolean
        --- GPU-constant / output-buffer naming root. Defaults to `name`;
        --- set when the `gpuTypes` constants use a different prefix
        --- (e.g. "Rect" for the "Rectangle" component).
        prefix: string
        --- Optional overrides. `plural` defaults to `prefix .. "s"`;
        --- `sizeHintKey` defaults to `plural:lower()`; `outputFormat`
        --- defaults to `gpuTypes.<PREFIX>_FORMAT`.
        plural: string
        sizeHintKey: string
        outputFormat: love.graphics.BufferFormat
    end

    record ShaderSet
        render: love.graphics.Shader
        cull: love.graphics.ComputeShader
        shadowMask: love.graphics.Shader
    end

    record ShaderConfig
        --- Base shader name, e.g. "circle": loads `<dir><name>.glsl`.
        name: string
        --- Shader directory, e.g. "tecs2d/gfx/internal/circle/".
        dir: string
        --- Cull shader base name; defaults to `<name>_cull`.
        cull: string
        --- Shared shadow-mask shader suffix (loads `shadow_mask_<value>`);
        --- omit for shapes without a raymarched shadow silhouette.
        shadowMask: string
    end

    register: function(world: tecs.World, config: Config)

    --- Compile a shape's shader set by naming convention and register
    --- the render source with the material compiler under `name`.
    loadShaders: function(config: ShaderConfig): ShaderSet
end

function define_shape.loadShaders(config: define_shape.ShaderConfig): define_shape.ShaderSet
    local name <const> = config.name
    local renderSource <const> = shaderUtils.loadRenderShader(name, config.dir)
    material_compiler.registerBaseSource(name, renderSource)
    local shadowMask: love.graphics.Shader = nil
    if config.shadowMask then
        shadowMask = lg.newShader(shaderUtils.loadShader("shadow_mask_" .. config.shadowMask))
    end
    return {
        render = lg.newShader(renderSource),
        cull = lg.newComputeShader(shaderUtils.loadCullShader(config.cull or (name .. "_cull"), config.dir)),
        shadowMask = shadowMask,
    }
end

function define_shape.register(world: tecs.World, config: define_shape.Config)
    local name <const> = config.name
    local lower <const> = name:lower()
    local prefix <const> = config.prefix or name
    local prefixUpper <const> = prefix:upper()
    local plural <const> = config.plural or (prefix .. "s")
    local primaryLayout <const> = modifier_binding.layoutFor(config.component)

    -- Look up a `gpuTypes.<PREFIX><suffix>` constant by naming convention.
    local function gt(suffix: string): any
        local v = gtByName[prefixUpper .. suffix]
        if v == nil then
            error("defineShape: missing gpuTypes." .. prefixUpper .. suffix
                .. " for shape '" .. name .. "'")
        end
        return v
    end

    local tagFlags: {shadow_plugin.TagFlagBinding} = {}
    if config.tags then
        for i = 1, #config.tags do
            local t <const> = config.tags[i]
            tagFlags[i] = {component = t, flag = modifier_binding.flagFor(t)}
        end
    end

    shadow_plugin.register(world, {
        prefix = prefix,
        plural = plural,
        materialShapeName = lower,
        sizeHintKey = config.sizeHintKey or plural:lower(),
        registryName = lower .. ".shadows",
        renderStateSystemName = lower .. ".ShadowRenderState",
        uploadSystemName = lower .. ".ShadowUpload",

        primary = config.component,
        primaryLayout = primaryLayout,
        primaryInputName = name .. "Input",

        optional = modifier_binding.bind(config.modifiers),
        tagFlags = tagFlags,

        cullShader = config.cull,
        renderShader = config.render,
        shadowMaskShader = config.shadowMask,
        outputFormat = config.outputFormat or gt("_FORMAT") as love.graphics.BufferFormat,
        outputName = prefix .. "Output",
        -- Only named when a shadow pass exists (the buffer is otherwise
        -- never allocated); matches the explicit descriptors' "".
        shadowOutputName = config.shadowMask and (prefix .. "ShadowOutput") or "",

        stub = {
            transformFormat = gt("_TRANSFORM_FORMAT") as love.graphics.BufferFormat,
            transformCtype = gt("_TRANSFORM_CTYPE") as string,
            metadataFormat = gt("_METADATA_FORMAT") as love.graphics.BufferFormat,
            metadataCtype = gt("_METADATA_CTYPE") as string,
            inputFormat = gt("_FORMAT") as love.graphics.BufferFormat,
            inputCtype = gt("_CTYPE") as string,
        },

        hasShadow = config.shadowMask ~= nil,
        hasAlphaBlendFilter = config.alphaBlendFilter,
    })
end

return define_shape
