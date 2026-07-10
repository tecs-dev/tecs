--[[
    Layer Effects Demo

    Demonstrates per-layer shader effects.
    Interactive layer stack UI for toggling effects per layer.
    Supports multiple effects per layer (stacked in order: blur, invert, desat).

    Layers:
    1 - Floor: green checkered (parallax 0.5x, slower)
    2 - Circles: animated rainbow circles (normal parallax)
    3 - Squares: colorful parallax layer (2x, faster)
    4 - HUD: layer controls

    Available Effects:
    - Blur: 2-pass separable Gaussian blur
    - Invert: Color inversion
    - Desat: Desaturation (grayscale)

    Controls:
    - Up/Down: Select layer
    - Left/Right: Select effect
    - Enter: Toggle effect on selected layer
    - WASD: Move camera
    - +/-: Zoom in/out
    - ESC: Quit
]]

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local input <const> = require("tecs2d.input")
local floor <const> = require("floor")

local Text <const> = gfx.Text
local Transform <const> = tecs.builtins.Transform
local FONT_PATH <const> = "assets/press-start-2p.fnt"

-- Color palette for squares (warm sunset tones)
local SQUARE_PALETTE <const>: {{number, number, number, number}} = {
    {0.95, 0.6, 0.4, 0.7},   -- coral
    {0.85, 0.45, 0.55, 0.7}, -- rose
    {0.7, 0.4, 0.6, 0.7},    -- mauve
    {0.55, 0.45, 0.7, 0.7},  -- lavender
    {0.4, 0.5, 0.8, 0.7},    -- periwinkle
    {0.3, 0.6, 0.75, 0.7},   -- sky blue
    {0.35, 0.7, 0.6, 0.7},   -- teal
    {0.5, 0.75, 0.45, 0.7},  -- sage
}
local VIRTUAL_HEIGHT <const> = 360

local sin, cos <const> = math.sin, math.cos

local GRID_SIZE <const> = 64
local WORLD_SIZE <const> = 2000
local NUM_CIRCLES <const> = 200
local NUM_SQUARES <const> = 600
local SQUARE_SPREAD <const> = 1500
local CAMERA_SPEED <const> = 400

-------------------------------------------------------------------------------
-- Effect shaders
-------------------------------------------------------------------------------

local BLUR_SHADER_CODE <const> = [[
extern vec2 direction;
extern number radius;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 sum = vec4(0.0);
    float totalWeight = 0.0;
    vec2 texSize = vec2(textureSize(tex, 0));
    vec2 pixelDir = direction / texSize;

    for (float i = -radius; i <= radius; i += 1.0) {
        float weight = 1.0 - abs(i) / (radius + 1.0);
        weight = weight * weight;
        sum += Texel(tex, tc + pixelDir * i) * weight;
        totalWeight += weight;
    }

    return sum / totalWeight * color;
}
]]

local INVERT_SHADER_CODE <const> = [[
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 pixel = Texel(tex, tc);
    return vec4(1.0 - pixel.r, 1.0 - pixel.g, 1.0 - pixel.b, pixel.a) * color;
}
]]

local DESATURATE_SHADER_CODE <const> = [[
extern number strength;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 pixel = Texel(tex, tc);
    float gray = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
    vec3 desaturated = mix(pixel.rgb, vec3(gray), strength);
    return vec4(desaturated, pixel.a) * color;
}
]]

-------------------------------------------------------------------------------
-- Layer and Effect definitions
-------------------------------------------------------------------------------

local LAYER_NAMES <const>: {string} = {"floor  ", "circles", "squares"}
-- Effects that can be toggled (excluding "none" which clears all)
local EFFECT_NAMES <const>: {string} = {"blur", "invert", "desat"}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local record DemoState
    pipeline: gfx.Pipeline
    selectedLayer: integer      -- 1-3
    selectedEffect: integer     -- 1-3 (index into EFFECT_NAMES)
    -- Each layer has a set of active effects (effect name -> true if active)
    layerEffects: {{string: boolean}}
    blurH: love.graphics.Shader
    blurV: love.graphics.Shader
    invertShader: love.graphics.Shader
    desaturateShader: love.graphics.Shader
    -- HUD entity IDs for updating
    layerTexts: {integer}       -- text entities for each layer row
    effectText: integer         -- current effect selector text
    helpText: integer
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<DemoState>

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Returns shaders and uniforms for an effect
local function getShaderForEffect(state: DemoState, effectName: string): {love.graphics.Shader}, {string: any}
    if effectName == "blur" then
        return {state.blurH, state.blurV}, { radius = 8.0 }
    elseif effectName == "invert" then
        return {state.invertShader}, nil
    elseif effectName == "desat" then
        return {state.desaturateShader}, { strength = 1.0 }
    end
    return nil, nil
end

-- Apply all active effects for a layer
local function applyLayerEffects(state: DemoState, layerNum: integer)
    local effects = state.layerEffects[layerNum]
    state.pipeline:clearLayerEffect(layerNum)

    -- Collect all shaders from active effects
    local allShaders: {love.graphics.Shader} = {}
    local allUniforms: {string: any} = {}

    -- Apply in consistent order: blur, invert, desat
    for _, effectName in ipairs(EFFECT_NAMES) do
        if effects[effectName] then
            local shaders, uniforms = getShaderForEffect(state, effectName)
            if shaders then
                for _, s in ipairs(shaders) do
                    table.insert(allShaders, s)
                end
                if uniforms then
                    for k, v in pairs(uniforms) do
                        allUniforms[k] = v
                    end
                end
            end
        end
    end

    if #allShaders > 0 then
        state.pipeline:setLayerEffect(layerNum, allShaders as any, allUniforms, { singleLayer = true })
    end
end

-- Build effect string for display (e.g., "B+I" or "---")
local function buildEffectString(effects: {string: boolean}): string
    local parts: {string} = {}
    if effects["blur"] then table.insert(parts, "B") end
    if effects["invert"] then table.insert(parts, "I") end
    if effects["desat"] then table.insert(parts, "D") end
    if #parts == 0 then
        return "---"
    end
    return table.concat(parts, "+")
end

local function updateHUD(world: tecs.World, state: DemoState)
    -- Update layer stack display
    for i = 1, 3 do
        local textEntity = state.layerTexts[i]
        local bt = world:get(textEntity, Text)
        if bt then
            local effects = state.layerEffects[i]
            local prefix = (i == state.selectedLayer) and "> " or "  "
            local effectStr = buildEffectString(effects)
            bt:setText(prefix .. i .. " " .. LAYER_NAMES[i] .. " [" .. effectStr .. "]")
        end
        local color = world:get(textEntity, gfx.Color)
        if color then
            if i == state.selectedLayer then
                color.r, color.g, color.b = 1.0, 1.0, 0.3
            else
                color.r, color.g, color.b = 0.6, 0.6, 0.6
            end
        end
    end

    -- Update effect selector (show which effect is selected, mark active ones)
    local effectBt = world:get(state.effectText, Text)
    if effectBt then
        local parts: {string} = {}
        local currentLayerEffects = state.layerEffects[state.selectedLayer]
        for i, name in ipairs(EFFECT_NAMES) do
            local isActive = currentLayerEffects[name] or false
            local marker = isActive and "*" or " "
            if i == state.selectedEffect then
                table.insert(parts, "[" .. marker .. name .. "]")
            else
                table.insert(parts, " " .. marker .. name .. " ")
            end
        end
        effectBt:setText(table.concat(parts, ""))
    end
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local function layerFxPlugin(world: tecs.World)
    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Create effect shaders
    local blurH = love.graphics.newShader(BLUR_SHADER_CODE)
    local blurV = love.graphics.newShader(BLUR_SHADER_CODE)
    blurH:send("direction", {1.0, 0.0})
    blurV:send("direction", {0.0, 1.0})
    local invertShader = love.graphics.newShader(INVERT_SHADER_CODE)
    local desaturateShader = love.graphics.newShader(DESATURATE_SHADER_CODE)

    -- Background: green checkered floor on layer 1
    floor.spawnCheckered(world, {
        worldWidth = WORLD_SIZE * 8,
        worldHeight = WORLD_SIZE * 8,
        tileSize = GRID_SIZE * 2,
        layer = 1,
        offsetX = -WORLD_SIZE * 4,
        offsetY = -WORLD_SIZE * 4,
    })

    -- Circles: animated rainbow on layer 2
    for i = 1, NUM_CIRCLES do
        local angle = (i / NUM_CIRCLES) * math.pi * 2
        local radius = 100 + (i % 5) * 80
        local x = cos(angle) * radius
        local y = sin(angle) * radius
        local hue = (i / NUM_CIRCLES) * 6
        local r, g, b: number, number, number
        local h = hue % 6
        if h < 1 then r, g, b = 1, h, 0
        elseif h < 2 then r, g, b = 2-h, 1, 0
        elseif h < 3 then r, g, b = 0, 1, h-2
        elseif h < 4 then r, g, b = 0, 4-h, 1
        elseif h < 5 then r, g, b = h-4, 0, 1
        else r, g, b = 1, 0, 6-h end
        world:spawn(
            Transform(x, y, 0, 2),
            gfx.Circle(10 + (i % 3) * 5),
            gfx.Color(r, g, b, 1)
        )
    end

    -- Squares: parallax layer 3, palette colors
    for i = 1, NUM_SQUARES do
        local x = (math.random() - 0.5) * SQUARE_SPREAD * 2
        local y = (math.random() - 0.5) * SQUARE_SPREAD * 2
        local size = 20 + math.random(0, 30)
        local color = SQUARE_PALETTE[(i % #SQUARE_PALETTE) + 1]
        world:spawn(
            Transform(x, y, 0, 3),
            gfx.Rectangle(size, size),
            gfx.Color(color[1], color[2], color[3], color[4])
        )
    end

    -- HUD: Layer stack on bottom right
    -- Note: virtual width = virtualHeight * aspectRatio = 360 * (960/720) = 480
    local virtualWidth = VIRTUAL_HEIGHT * (960 / 720)
    local hudX = virtualWidth - 190
    local hudY = VIRTUAL_HEIGHT - 80
    local layerTexts: {integer} = {}

    -- Background for layer stack (semi-transparent dark rectangle, 50% opacity)
    world:spawn(
        Transform(hudX + 90, hudY + 20, 0, 4),
        gfx.Rectangle(200, 80, 0),
        gfx.Color(0, 0, 0, 0.5),
        gfx.BlendMode("alpha")
    )

    for i = 1, 3 do
        local rowY = hudY + (3 - i) * 12  -- stack from bottom up
        local prefix = (i == 1) and "> " or "  "  -- layer 1 selected initially
        local r, g, b = 0.6, 0.6, 0.6
        if i == 1 then r, g, b = 1.0, 1.0, 0.3 end  -- highlight selected
        local textId = world:spawn(
            Transform(hudX, rowY, 1, 4),
            Text(FONT_PATH, prefix .. i .. " " .. LAYER_NAMES[i] .. " [---]", 0.5),
            gfx.Color(r, g, b, 1),
            gfx.Pivot(0, 0)
        )
        layerTexts[i] = textId
    end

    -- Effect selector below layer stack (aligned with layer text)
    local effectText = world:spawn(
        Transform(hudX, hudY + 50, 1, 4),
        Text(FONT_PATH, "[ blur] invert  desat", 0.5),
        gfx.Color(0.8, 0.8, 0.8, 1),
        gfx.Pivot(0, 0)
    )

    -- Help text on bottom left (white text, no background)
    local helpText = world:spawn(
        Transform(10, VIRTUAL_HEIGHT - 14, 1, 4),
        Text(FONT_PATH, "Arrows:Select  Enter:Toggle  WASD:Move", 0.5),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    local state: DemoState = {
        pipeline = pipeline,
        selectedLayer = 1,
        selectedEffect = 1,
        layerEffects = {{}, {}, {}},  -- empty sets for each layer
        blurH = blurH,
        blurV = blurV,
        invertShader = invertShader,
        desaturateShader = desaturateShader,
        layerTexts = layerTexts,
        effectText = effectText,
        helpText = helpText,
    }
    world.resources[STATE_KEY] = state

    -- Animate circles
    local circleQuery = world:query({
        name = "Circles",
        include = {Transform, gfx.Circle},
    })

    world:addSystem({
        name = "AnimateCircles",
        phase = tecs.phases.Update,
        run = function(_dt: number)
            local time = state.pipeline:getTime()
            local i = 0
            for archetype, len in circleQuery:iter() do
                local transforms = archetype:getMut(Transform)
                for row = 1, len do
                    i = i + 1
                    local t = transforms[row]
                    local angle = (i / NUM_CIRCLES) * math.pi * 2 + time * 0.5
                    local radius = 100 + (i % 5) * 80
                    t.x = cos(angle) * radius
                    t.y = sin(angle) * radius
                end
            end
        end
    })

    -- Input handling
    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.First,
        run = function(dt: number)
            local hudChanged = false

            -- Layer selection (up/down)
            if input.isKeyPressed("up") then
                state.selectedLayer = state.selectedLayer + 1
                if state.selectedLayer > 3 then state.selectedLayer = 1 end
                hudChanged = true
            elseif input.isKeyPressed("down") then
                state.selectedLayer = state.selectedLayer - 1
                if state.selectedLayer < 1 then state.selectedLayer = 3 end
                hudChanged = true
            end

            -- Effect selection (left/right)
            if input.isKeyPressed("right") then
                state.selectedEffect = state.selectedEffect + 1
                if state.selectedEffect > #EFFECT_NAMES then state.selectedEffect = 1 end
                hudChanged = true
            elseif input.isKeyPressed("left") then
                state.selectedEffect = state.selectedEffect - 1
                if state.selectedEffect < 1 then state.selectedEffect = #EFFECT_NAMES end
                hudChanged = true
            end

            -- Toggle effect on selected layer (enter)
            if input.isKeyPressed("return") then
                local effectName = EFFECT_NAMES[state.selectedEffect]
                local effects = state.layerEffects[state.selectedLayer]
                -- Toggle the effect
                if effects[effectName] then
                    effects[effectName] = nil
                else
                    effects[effectName] = true
                end
                applyLayerEffects(state, state.selectedLayer)
                hudChanged = true
            end

            if hudChanged then
                updateHUD(world, state)
            end

            -- Camera movement
            local cam = pipeline:getCamera()
            local dx, dy: number, number = 0, 0
            if input.isKeyDown("w") then dy = dy - CAMERA_SPEED * dt end
            if input.isKeyDown("s") then dy = dy + CAMERA_SPEED * dt end
            if input.isKeyDown("a") then dx = dx - CAMERA_SPEED * dt end
            if input.isKeyDown("d") then dx = dx + CAMERA_SPEED * dt end
            if dx ~= 0 or dy ~= 0 then
                local cx, cy = cam:getPosition()
                cam:setPosition(cx + dx, cy + dy)
            end

            -- Zoom
            if input.isKeyDown("=") then
                cam:setZoom(cam:getZoom() * 1.02)
            elseif input.isKeyDown("-") then
                cam:setZoom(cam:getZoom() / 1.02)
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = layerFxPlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {
            [1] = { name = "floor", sortMode = "z", parallaxX = 0.5, parallaxY = 0.5 },
            [2] = { name = "circles", sortMode = "z" },
            [3] = { name = "squares", parallaxX = 2.0, parallaxY = 2.0, sortMode = "z" },
            [4] = { name = "hud", space = "virtual", sortMode = "z" },
        },
    },
})
