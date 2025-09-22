--- TextEffects component for MSDF text rendering effects.
--- Supports outline, glow, and drop shadow effects on MSDF/SDF text.
--- Effects are packed into the GPU header during sync; zero values = no effect.

local tecs <const> = require("tecs")

local record TextEffects is tecs.Component
    --- Outline width in SDF units (0 = no outline)
    outlineWidth: number
    --- Outline color RGBA (0-1)
    outlineR: number
    outlineG: number
    outlineB: number
    outlineA: number

    --- Glow radius in SDF units (0 = no glow)
    glowRadius: number
    --- Glow color RGBA (0-1)
    glowR: number
    glowG: number
    glowB: number
    glowA: number

    --- Shadow offset in pixels
    shadowOffsetX: number
    shadowOffsetY: number
    --- Shadow blur in SDF units (0 = sharp)
    shadowBlur: number
    --- Shadow color RGBA (0-1)
    shadowR: number
    shadowG: number
    shadowB: number
    shadowA: number

    metamethod __call: function(self, config?: TextEffectsConfig): TextEffects
end

local record OutlineConfig
    width: number
    color: {number}
end

local record GlowConfig
    radius: number
    color: {number}
end

local record ShadowConfig
    offset: {number}
    blur: number
    color: {number}
end

local record TextEffectsConfig
    outline: OutlineConfig
    glow: GlowConfig
    shadow: ShadowConfig
end

local function applyConfig(eff: TextEffects, config: TextEffectsConfig)
    if not config then return end
    if config.outline then
        eff.outlineWidth = config.outline.width or 0
        local c = config.outline.color
        if c then
            eff.outlineR = c[1] or 0
            eff.outlineG = c[2] or 0
            eff.outlineB = c[3] or 0
            eff.outlineA = c[4] or 1
        end
    end
    if config.glow then
        eff.glowRadius = config.glow.radius or 0
        local c = config.glow.color
        if c then
            eff.glowR = c[1] or 0
            eff.glowG = c[2] or 0
            eff.glowB = c[3] or 0
            eff.glowA = c[4] or 1
        end
    end
    if config.shadow then
        local off = config.shadow.offset
        if off then
            eff.shadowOffsetX = off[1] or 0
            eff.shadowOffsetY = off[2] or 0
        end
        eff.shadowBlur = config.shadow.blur or 0
        local c = config.shadow.color
        if c then
            eff.shadowR = c[1] or 0
            eff.shadowG = c[2] or 0
            eff.shadowB = c[3] or 0
            eff.shadowA = c[4] or 1
        end
    end
end

tecs.newFFIComponent({
    name = "TextEffects",
    container = TextEffects,
    fields = {
        {"outlineWidth", "float"},
        {"outlineR", "float"},
        {"outlineG", "float"},
        {"outlineB", "float"},
        {"outlineA", "float"},
        {"glowRadius", "float"},
        {"glowR", "float"},
        {"glowG", "float"},
        {"glowB", "float"},
        {"glowA", "float"},
        {"shadowOffsetX", "float"},
        {"shadowOffsetY", "float"},
        {"shadowBlur", "float"},
        {"shadowR", "float"},
        {"shadowG", "float"},
        {"shadowB", "float"},
        {"shadowA", "float"},
    },
    -- TextEffects takes a nested config table ({outline = {...}, ...}) rather
    -- than positional fields, so the default codegen `.new` (which would map
    -- top-level data keys to field names) cannot construct it correctly.
    new = function(data: {string: any}): TextEffects
        local instance = (TextEffects as function(any): TextEffects)(data as TextEffectsConfig)
        return instance
    end,
    __call = function(instance: TextEffects, config?: TextEffectsConfig)
        applyConfig(instance, config)
    end,
    init = function(instance: TextEffects, config?: TextEffectsConfig)
        applyConfig(instance, config)
    end,
})

return TextEffects
