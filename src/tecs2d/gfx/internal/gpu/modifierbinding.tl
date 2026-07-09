--- Shared modifier-component binding for the shadow-column path.
---
--- Every content type (shapes, sprite, text, ...) that reads optional
--- modifier components -- Color, ClipBounds, Material, Pivot, Occluder,
--- etc. -- binds them the same way: a `{component, layout, mask, ssboName}`
--- entry per modifier, where the cull shader gates each read on
--- `ComponentMask & COMP_<NAME>`.
---
--- Three of those four fields are mechanical and derive from the
--- component name, so binding them here keeps content types in sync:
---   - `layout`   ← `std430.layouts[componentName]`
---   - `ssboName` ← `componentName .. "Input"`
---   - `mask`     ← the canonical `MASK` table below
---
--- This module derives all three from the component handle, so callers
--- pass only a list of handles. The `MASK` table is the single source of
--- truth for the `COMP_<NAME>` bit values -- every consuming cull shader
--- must match it. (Bit 0x4 is a historical reserved slot, left unused.)

local tecs <const> = require("tecs")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shadowdispatch <const> = require("tecs2d.gfx.internal.gpu.shadowdispatch")

local layoutsByName <const> = std430.layouts as {string: std430.Descriptor}

local record modifier_binding
    MASK: {string: integer}
    TAG_FLAG: {string: integer}

    maskFor: function(component: tecs.Component): integer
    layoutFor: function(component: tecs.Component): std430.Descriptor
    flagFor: function(component: tecs.Component): integer

    --- Derive a full `{OptionalBinding}` list from a list of modifier
    --- component handles (layout + ssboName + mask all derived).
    bind: function(components: {tecs.Component}): {shadowdispatch.OptionalBinding}
end

-- Global canonical modifier -> mask bit. The value MUST equal the
-- `COMP_<NAME>` define in every consuming cull shader. Low bits cover the
-- shape modifiers; 0x100+ the sprite/text-only ones. 0x4 reserved.
modifier_binding.MASK = {
    Color          = 0x1,
    ClipBounds     = 0x2,
    Occluder       = 0x8,
    Material       = 0x10,
    LayoutBox      = 0x20,
    Pivot          = 0x40,
    RoundedCorners = 0x80,
    DropShadow     = 0x100,
    RepeatedSprite = 0x200,
    SpriteData     = 0x400,
    TextEffects    = 0x800,
}

-- Tag component -> static flag (OR'd into the dispatch's StaticFlags).
modifier_binding.TAG_FLAG = {
    Unlit = gpuTypes.FLAG_UNLIT,
}

function modifier_binding.layoutFor(component: tecs.Component): std430.Descriptor
    local name <const> = component.componentName
    local layout <const> = layoutsByName[name]
    if not layout then
        error("modifier_binding: no std430 layout for component '"
            .. tostring(name) .. "'")
    end
    return layout
end

function modifier_binding.maskFor(component: tecs.Component): integer
    local name <const> = component.componentName
    local mask <const> = modifier_binding.MASK[name]
    if not mask then
        error("modifier_binding: no canonical mask bit for modifier '"
            .. tostring(name) .. "' (add it to MASK and match the cull GLSL)")
    end
    return mask
end

function modifier_binding.flagFor(component: tecs.Component): integer
    local name <const> = component.componentName
    local flag <const> = modifier_binding.TAG_FLAG[name]
    if not flag then
        error("modifier_binding: no canonical static flag for tag '"
            .. tostring(name) .. "'")
    end
    return flag
end

function modifier_binding.bind(components: {tecs.Component}): {shadowdispatch.OptionalBinding}
    local out: {shadowdispatch.OptionalBinding} = {}
    for i = 1, #components do
        local c <const> = components[i]
        out[i] = {
            component = c,
            layout = modifier_binding.layoutFor(c),
            mask = modifier_binding.maskFor(c),
            ssboName = c.componentName .. "Input",
        }
    end
    return out
end

return modifier_binding
