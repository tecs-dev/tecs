--[[
Blend mode tag components for GPU rendering.

15 tag components: 7 blend modes × 2 alpha modes, plus forward alpha.
These are mutually exclusive: adding one removes any other blend tag from the entity.

Usage:
    world:spawn(Circle(50), Transform(100, 100), AdditiveBlend())
    world:set(entityId, MultiplyBlend())  -- removes AdditiveBlend automatically
]]

local tecs <const> = require("tecs")

local type lg_BlendMode = love.graphics.BlendMode
local type lg_BlendAlphaMode = love.graphics.BlendAlphaMode

local record BlendInfo
    mode: lg_BlendMode
    alphaMode: lg_BlendAlphaMode
end

-- Individual blend component types
local record AdditiveBlend is tecs.Component end
local record AdditiveBlendPremul is tecs.Component end
local record MultiplyBlend is tecs.Component end
local record MultiplyBlendPremul is tecs.Component end
local record ScreenBlend is tecs.Component end
local record ScreenBlendPremul is tecs.Component end
local record SubtractBlend is tecs.Component end
local record SubtractBlendPremul is tecs.Component end
local record LightenBlend is tecs.Component end
local record LightenBlendPremul is tecs.Component end
local record DarkenBlend is tecs.Component end
local record DarkenBlendPremul is tecs.Component end
local record ReplaceBlend is tecs.Component end
local record ReplaceBlendPremul is tecs.Component end
local record ForwardAlphaBlend is tecs.Component end

local record blend
    -- Additive blending (glow, fire, light beams)
    AdditiveBlend: AdditiveBlend
    AdditiveBlendPremul: AdditiveBlendPremul

    -- Multiply blending (shadows, tinting, darkening)
    MultiplyBlend: MultiplyBlend
    MultiplyBlendPremul: MultiplyBlendPremul

    -- Screen blending (soft glow, lightening)
    ScreenBlend: ScreenBlend
    ScreenBlendPremul: ScreenBlendPremul

    -- Subtract blending (color removal, darkening)
    SubtractBlend: SubtractBlend
    SubtractBlendPremul: SubtractBlendPremul

    -- Lighten blending (max of each channel)
    LightenBlend: LightenBlend
    LightenBlendPremul: LightenBlendPremul

    -- Darken blending (min of each channel)
    DarkenBlend: DarkenBlend
    DarkenBlendPremul: DarkenBlendPremul

    -- Replace blending (no blending, overwrites destination)
    ReplaceBlend: ReplaceBlend
    ReplaceBlendPremul: ReplaceBlendPremul

    -- Ordinary alpha blending in the forward composite pass. Use for
    -- translucent content that must blend over another rendered entity,
    -- such as antialiased text over a UI panel.
    ForwardAlphaBlend: ForwardAlphaBlend

    -- Array of all blend components (for iteration with numeric for loops)
    ALL: {tecs.Component}

    -- Map component → blend mode info for batch lookup
    INFO: {tecs.Component: BlendInfo}

    -- Map blend ID → blend mode info (for rendering by ID)
    INFO_BY_ID: {integer: BlendInfo}

    -- Integer IDs for groupBy queries
    ID: {string: integer}

    -- groupBy function for queries - returns blend ID for an archetype
    groupBy: function(tecs.Archetype): integer

    -- Explicit mutex setter -- removes any other blend tag before
    -- setting the new one. Use instead of `world:set(id, mode)` when
    -- switching blend modes.
    set: function(world: tecs.World, entityId: integer, mode: tecs.Component)
end

-- Integer IDs for groupBy (sorted order for deterministic iteration)
blend.ID = {
    ADD = 1,
    ADD_PREMUL = 2,
    MULTIPLY = 3,
    MULTIPLY_PREMUL = 4,
    SCREEN = 5,
    SCREEN_PREMUL = 6,
    SUBTRACT = 7,
    SUBTRACT_PREMUL = 8,
    LIGHTEN = 9,
    LIGHTEN_PREMUL = 10,
    DARKEN = 11,
    DARKEN_PREMUL = 12,
    REPLACE = 13,
    REPLACE_PREMUL = 14,
    FORWARD_ALPHA = 15,
}

-- Array for iteration (populated as components are created)
blend.ALL = {}

-- Map component → blend info (populated as components are created)
blend.INFO = {}

-- Map blend ID → blend info (populated after components are created)
blend.INFO_BY_ID = {}

-- Explicit blend-mode mutex setter. Replaces any existing blend tag
-- on the entity with `mode`. Use this (instead of `world:set`) when
-- switching modes; plain `world:set(id, mode)` does NOT enforce
-- exclusivity between the tags.
function blend.set(world: tecs.World, entityId: integer, mode: tecs.Component)
    local all = blend.ALL
    for i = 1, #all do
        local comp = all[i]
        if comp ~= mode and world:has(entityId, comp) then
            world:remove(entityId, comp)
        end
    end
    world:set(entityId, mode)
end

-- Helper to create a blend tag component and register it
local function createBlendComponent(
    name: string,
    mode: lg_BlendMode,
    alphaMode: lg_BlendAlphaMode
): tecs.Component
    local comp = tecs.newTagComponent({
        name = name,
    })

    blend.ALL[#blend.ALL + 1] = comp
    blend.INFO[comp] = {
        mode = mode,
        alphaMode = alphaMode,
    }

    return comp
end

-- Create all blend components.
blend.AdditiveBlend = createBlendComponent(
    "AdditiveBlend", "add", "alphamultiply") as AdditiveBlend
blend.AdditiveBlendPremul = createBlendComponent(
    "AdditiveBlendPremul", "add", "premultiplied") as AdditiveBlendPremul

-- LÖVE only permits the multiply, lighten, and darken blend modes with
-- premultiplied alpha (setBlendMode errors otherwise), so their
-- non-Premul tags register as premultiplied too. For SDF shapes the two
-- are numerically identical (their shaders output alpha 1).
blend.MultiplyBlend = createBlendComponent(
    "MultiplyBlend", "multiply", "premultiplied") as MultiplyBlend
blend.MultiplyBlendPremul = createBlendComponent(
    "MultiplyBlendPremul", "multiply", "premultiplied") as MultiplyBlendPremul

blend.ScreenBlend = createBlendComponent(
    "ScreenBlend", "screen", "alphamultiply") as ScreenBlend
blend.ScreenBlendPremul = createBlendComponent(
    "ScreenBlendPremul", "screen", "premultiplied") as ScreenBlendPremul

blend.SubtractBlend = createBlendComponent(
    "SubtractBlend", "subtract", "alphamultiply") as SubtractBlend
blend.SubtractBlendPremul = createBlendComponent(
    "SubtractBlendPremul", "subtract", "premultiplied") as SubtractBlendPremul

blend.LightenBlend = createBlendComponent(
    "LightenBlend", "lighten", "premultiplied") as LightenBlend
blend.LightenBlendPremul = createBlendComponent(
    "LightenBlendPremul", "lighten", "premultiplied") as LightenBlendPremul

blend.DarkenBlend = createBlendComponent(
    "DarkenBlend", "darken", "premultiplied") as DarkenBlend
blend.DarkenBlendPremul = createBlendComponent(
    "DarkenBlendPremul", "darken", "premultiplied") as DarkenBlendPremul

blend.ReplaceBlend = createBlendComponent(
    "ReplaceBlend", "replace", "alphamultiply") as ReplaceBlend
blend.ReplaceBlendPremul = createBlendComponent(
    "ReplaceBlendPremul", "replace", "premultiplied") as ReplaceBlendPremul
blend.ForwardAlphaBlend = createBlendComponent(
    "ForwardAlphaBlend", "alpha", "alphamultiply") as ForwardAlphaBlend

-- Populate INFO_BY_ID for blend ID → blend info lookup
blend.INFO_BY_ID[blend.ID.ADD] = blend.INFO[blend.AdditiveBlend]
blend.INFO_BY_ID[blend.ID.ADD_PREMUL] = blend.INFO[blend.AdditiveBlendPremul]
blend.INFO_BY_ID[blend.ID.MULTIPLY] = blend.INFO[blend.MultiplyBlend]
blend.INFO_BY_ID[blend.ID.MULTIPLY_PREMUL] = blend.INFO[blend.MultiplyBlendPremul]
blend.INFO_BY_ID[blend.ID.SCREEN] = blend.INFO[blend.ScreenBlend]
blend.INFO_BY_ID[blend.ID.SCREEN_PREMUL] = blend.INFO[blend.ScreenBlendPremul]
blend.INFO_BY_ID[blend.ID.SUBTRACT] = blend.INFO[blend.SubtractBlend]
blend.INFO_BY_ID[blend.ID.SUBTRACT_PREMUL] = blend.INFO[blend.SubtractBlendPremul]
blend.INFO_BY_ID[blend.ID.LIGHTEN] = blend.INFO[blend.LightenBlend]
blend.INFO_BY_ID[blend.ID.LIGHTEN_PREMUL] = blend.INFO[blend.LightenBlendPremul]
blend.INFO_BY_ID[blend.ID.DARKEN] = blend.INFO[blend.DarkenBlend]
blend.INFO_BY_ID[blend.ID.DARKEN_PREMUL] = blend.INFO[blend.DarkenBlendPremul]
blend.INFO_BY_ID[blend.ID.REPLACE] = blend.INFO[blend.ReplaceBlend]
blend.INFO_BY_ID[blend.ID.REPLACE_PREMUL] = blend.INFO[blend.ReplaceBlendPremul]
blend.INFO_BY_ID[blend.ID.FORWARD_ALPHA] = blend.INFO[blend.ForwardAlphaBlend]

-- groupBy function for queries - returns blend ID for an archetype
-- (0 = deferred alpha, 1-15 = forward blend modes).
local blendAll = blend.ALL
local blendIdMap = blend.ID
function blend.groupBy(archetype: tecs.Archetype): integer
    if archetype:get(blendAll[1]) then return blendIdMap.ADD end
    if archetype:get(blendAll[2]) then return blendIdMap.ADD_PREMUL end
    if archetype:get(blendAll[3]) then return blendIdMap.MULTIPLY end
    if archetype:get(blendAll[4]) then return blendIdMap.MULTIPLY_PREMUL end
    if archetype:get(blendAll[5]) then return blendIdMap.SCREEN end
    if archetype:get(blendAll[6]) then return blendIdMap.SCREEN_PREMUL end
    if archetype:get(blendAll[7]) then return blendIdMap.SUBTRACT end
    if archetype:get(blendAll[8]) then return blendIdMap.SUBTRACT_PREMUL end
    if archetype:get(blendAll[9]) then return blendIdMap.LIGHTEN end
    if archetype:get(blendAll[10]) then return blendIdMap.LIGHTEN_PREMUL end
    if archetype:get(blendAll[11]) then return blendIdMap.DARKEN end
    if archetype:get(blendAll[12]) then return blendIdMap.DARKEN_PREMUL end
    if archetype:get(blendAll[13]) then return blendIdMap.REPLACE end
    if archetype:get(blendAll[14]) then return blendIdMap.REPLACE_PREMUL end
    if archetype:get(blendAll[15]) then return blendIdMap.FORWARD_ALPHA end
    return 0  -- Default alpha blend
end

return blend
