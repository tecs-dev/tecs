--- Layer effects system for per-layer shader effects.
--- Provides per-layer filters (blur, color grading, etc.)
---
--- By default, effects apply to the layer AND all layers below.
--- Set singleLayer = true to only affect the specified layer.

local lg <const> = love.graphics

-- Compositing shader for non-effect layer groups.
-- In the G-buffer, depth testing makes all entities "opaque" (winner takes all).
-- The single-pass path draws the albedo to screen with alpha blending against
-- the black screen clear: result = color * alpha + black * (1 - alpha).
-- To replicate this in multi-pass, pre-multiply alpha into the color (matching
-- the darkening from alpha against black) and force alpha=1 so the pixel
-- composites opaquely over the accumulator without blending with layers below.
local COMPOSITE_SHADER_CODE <const> = [[
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 pixel = Texel(tex, tc);
    if (pixel.a < 0.01) discard;
    return vec4(pixel.rgb * pixel.a, 1.0) * color;
}
]]

local record layer_effects
    --- Options for layer effects
    record EffectOptions
        singleLayer: boolean  -- If true, only affects this layer. Default: false (affects layer and all below)
    end

    --- A shader effect applied to a specific layer.
    --- Supports single or multi-pass effects (e.g., separable Gaussian blur).
    record LayerEffect
        shaders: {love.graphics.Shader}
        uniforms: {string: any}
        singleLayer: boolean  -- If true, only affects this layer; if false, affects layer and all below
    end

    --- A contiguous range of layers rendered together
    record LayerGroup
        minLayer: integer
        maxLayer: integer
        effect: LayerEffect          -- nil if no effect
        applyToAccumulator: boolean  -- If true, apply effect to entire accumulator (for "layers below" mode)
    end

    --- Layer effects manager
    record Manager
        effects: {integer: LayerEffect}  -- layer -> effect
        groups: {LayerGroup}             -- computed layer groups
        dirty: boolean                   -- needs recomputation
        maxLayers: integer

        -- Render targets for effect processing (world phase, at scaled resolution)
        accumulator: love.graphics.Canvas      -- Final composited result
        effectTemp: love.graphics.Canvas       -- Temp for effect application
        litLayer: love.graphics.Canvas         -- Single layer group after lighting
        compositeShader: love.graphics.Shader  -- Pre-multiplies alpha for opaque compositing

        setEffect: function(Manager, layer: integer, shader: any, uniforms?: {string: any}, options?: EffectOptions)
        clearEffect: function(Manager, layer: integer)
        hasEffects: function(Manager): boolean
        getGroups: function(Manager): {LayerGroup}
        resize: function(Manager, width: integer, height: integer)
    end

    --- Create a new layer effects manager
    new: function(maxLayers: integer, width: integer, height: integer): Manager
end

local MANAGER_MT <const>: metatable<layer_effects.Manager> = {
    __index = layer_effects.Manager,
}

function layer_effects.new(maxLayers: integer, width: integer, height: integer): layer_effects.Manager
    local manager: layer_effects.Manager = setmetatable({
        effects = {},
        groups = {},
        dirty = true,
        maxLayers = maxLayers,
        accumulator = lg.newCanvas(width, height),
        effectTemp = lg.newCanvas(width, height),
        litLayer = lg.newCanvas(width, height),
        compositeShader = lg.newShader(COMPOSITE_SHADER_CODE),
    }, MANAGER_MT)

    return manager
end

function layer_effects.Manager:setEffect(layer: integer, shader: any, uniforms?: {string: any}, options?: layer_effects.EffectOptions)
    if layer < 1 or layer > self.maxLayers then
        error("Layer " .. layer .. " out of range (1-" .. self.maxLayers .. ")")
    end
    if shader == nil then
        error("setEffect: shader is nil")
    end

    -- Normalize to a list of shaders (accepts Shader or {Shader}).
    -- A list is detected by presence of index 1; a single Shader is cdata/userdata.
    local shaders: {love.graphics.Shader}
    if type(shader) == "table" then
        local asList = shader as {love.graphics.Shader}
        if #asList == 0 then
            error("setEffect: shader list is empty; provide at least one shader")
        end
        shaders = asList
    else
        shaders = {shader as love.graphics.Shader}
    end

    local singleLayer = options and options.singleLayer or false

    self.effects[layer] = {
        shaders = shaders,
        uniforms = uniforms or {},
        singleLayer = singleLayer,
    }
    self.dirty = true
end

function layer_effects.Manager:clearEffect(layer: integer)
    self.effects[layer] = nil
    self.dirty = true
end

function layer_effects.Manager:hasEffects(): boolean
    return next(self.effects) ~= nil
end

function layer_effects.Manager:getGroups(): {layer_effects.LayerGroup}
    if not self.dirty then
        return self.groups
    end

    -- Collect layers that have effects
    local effectLayers: {integer} = {}
    for layer, _ in pairs(self.effects) do
        table.insert(effectLayers, layer)
    end
    table.sort(effectLayers)

    -- Build groups based on effect modes
    local groups: {layer_effects.LayerGroup} = {}
    local currentMin = 1

    for _, effectLayer in ipairs(effectLayers) do
        local effect = self.effects[effectLayer]

        if effect.singleLayer then
            -- Single-layer mode: effect only applies to this layer
            -- Create a group for layers before this effect (if any)
            if effectLayer > currentMin then
                table.insert(groups, {
                    minLayer = currentMin,
                    maxLayer = effectLayer - 1,
                })
            end

            -- The effect layer itself (single layer group, effect applied before compositing)
            table.insert(groups, {
                minLayer = effectLayer,
                maxLayer = effectLayer,
                effect = effect,
                applyToAccumulator = false,
            })

            currentMin = effectLayer + 1
        else
            -- "Layers below" mode: effect applies to this layer and all below
            -- Render all layers from currentMin to effectLayer, composite, then apply effect to accumulator
            table.insert(groups, {
                minLayer = currentMin,
                maxLayer = effectLayer,
                effect = effect,
                applyToAccumulator = true,  -- Apply effect to entire accumulator after compositing
            })

            currentMin = effectLayer + 1
        end
    end

    -- Remaining layers after last effect
    if currentMin <= self.maxLayers then
        table.insert(groups, {
            minLayer = currentMin,
            maxLayer = self.maxLayers,
        })
    end

    -- If no effects, just one group covering all layers
    if #groups == 0 then
        table.insert(groups, {
            minLayer = 1,
            maxLayer = self.maxLayers,
        })
    end

    self.groups = groups
    self.dirty = false
    return groups
end

function layer_effects.Manager:resize(width: integer, height: integer)
    self.accumulator = lg.newCanvas(width, height)
    self.effectTemp = lg.newCanvas(width, height)
    self.litLayer = lg.newCanvas(width, height)
end

return layer_effects
