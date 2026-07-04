--- MSDF Text Rendering Example
--- Demonstrates MSDF fonts at various scales, rotation, and text effects.
--- TAB toggles between MSDF and bitmap rendering for side-by-side comparison.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local mcp <const> = require("tecs2d.mcp")

local Transform <const> = tecs.builtins.Transform
local Text <const> = gfx.Text
local Color <const> = gfx.Color
local TextEffects <const> = gfx.TextEffects
local Pivot <const> = gfx.Pivot

local MSDF_FONT <const> = "assets/firacode-nerd-msdf.json"
local BITMAP_FONT <const> = "assets/firacode-nerd.fnt"

-- Both fonts are size 42 from the same typeface; bitmap xadvance corrected to match MSDF.
local BITMAP_SCALE_FACTOR <const> = 1

local WORLD_LAYER <const> = 1

local pi <const> = math.pi
local sin <const> = math.sin
local min <const> = math.min
local max <const> = math.max

local CAMERA_SPEED <const> = 600
local ZOOM_SPEED <const> = 1.5

local record TextEntry
    text: string
    scale: number
    x: number
    y: number
    r: number
    g: number
    b: number
    rotation: number
    sxMul: number
    syMul: number
    effects: gfx.TextEffects
end

local record EntityPair
    msdfId: integer
    bitmapId: integer
    sx: number
    sy: number
end

local function examplePlugin(world: tecs.World)
    world:addPlugin(mcp.new())

    love.graphics.setBackgroundColor(0.12, 0.13, 0.18)

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(550, 400)

    local entries: {TextEntry} = {
        -- Scale comparison (left column)
        { text = "Scale 0.5x", scale = 0.5, x = 80, y = 40, r = 0.8, g = 0.85, b = 0.9 },
        { text = "Scale 1x", scale = 1.0, x = 80, y = 80, r = 1, g = 1, b = 1 },
        { text = "Scale 2x", scale = 2.0, x = 80, y = 150, r = 0.6, g = 0.9, b = 1.0 },
        { text = "Scale 4x", scale = 4.0, x = 80, y = 280, r = 0.4, g = 0.7, b = 1.0 },

        -- Colored text (right column)
        { text = "Crimson", scale = 2.0, x = 700, y = 40, r = 0.9, g = 0.2, b = 0.2 },
        { text = "Emerald", scale = 2.0, x = 700, y = 160, r = 0.2, g = 0.9, b = 0.4 },
        { text = "Gold", scale = 2.0, x = 700, y = 280, r = 1.0, g = 0.85, b = 0.3 },
        { text = "Violet", scale = 2.0, x = 700, y = 400, r = 0.7, g = 0.3, b = 1.0 },

        -- Rotated
        { text = "Rotated 15", scale = 1.0, x = 200, y = 580, r = 1, g = 0.9, b = 0.5,
            rotation = pi / 12, sxMul = 2, syMul = 2 },
        { text = "Rotated 45", scale = 1.0, x = 550, y = 580, r = 0.5, g = 1, b = 0.7,
            rotation = pi / 4, sxMul = 2, syMul = 2 },
        { text = "Rotated -30", scale = 1.0, x = 900, y = 580, r = 1, g = 0.5, b = 0.8,
            rotation = -pi / 6, sxMul = 2, syMul = 2 },
    }

    local fxY = 750
    local fxEntries: {TextEntry} = {
        { text = "Outline", scale = 3.0, x = 80, y = fxY, r = 1, g = 1, b = 1,
            effects = TextEffects.new({ outline = { width = 0.15, color = {0, 0, 0, 1} } }) },
        { text = "Glow", scale = 3.0, x = 80, y = fxY + 180, r = 1, g = 1, b = 1,
            effects = TextEffects.new({ glow = { radius = 1.0, color = {0, 1, 0.2, 1.0} } }) },
        { text = "Shadow", scale = 3.0, x = 80, y = fxY + 360, r = 1, g = 1, b = 1,
            effects = TextEffects.new({ shadow = { offset = {3, 3}, blur = 0.05, color = {0, 0, 0, 0.8} } }) },
        { text = "All FX", scale = 3.0, x = 700, y = fxY + 180, r = 0.2, g = 0.6, b = 1,
            effects = TextEffects.new({
                outline = { width = 0.1, color = {0, 0, 0.3, 1} },
                glow = { radius = 2.0, color = {0.3, 0.5, 1, 0.8} },
                shadow = { offset = {4, 4}, blur = 0.08, color = {0, 0, 0, 0.6} },
            }) },
    }

    -- Spawn paired entities (MSDF + bitmap at same position)
    local pairs: {EntityPair} = {}

    local function spawnPair(e: TextEntry)
        local rot = e.rotation or 0
        local sx = e.sxMul or 1
        local sy = e.syMul or 1

        local msdfComps: {tecs.Component} = {
            Transform(e.x, e.y, 0, WORLD_LAYER, rot, sx, sy),
            Text(MSDF_FONT, e.text, e.scale),
            Color(e.r, e.g, e.b, 1), Pivot(0, 0),
        }
        if e.effects then
            table.insert(msdfComps, e.effects)
        end
        local msdfId = world:spawn(table.unpack(msdfComps))

        local bitmapId = world:spawn(
            Transform(e.x, e.y, 0, WORLD_LAYER, rot, sx, sy),
            Text(BITMAP_FONT, e.text, e.scale * BITMAP_SCALE_FACTOR),
            Color(e.r, e.g, e.b, 1), Pivot(0, 0))

        table.insert(pairs, { msdfId = msdfId, bitmapId = bitmapId, sx = sx, sy = sy } as EntityPair)
    end

    for _, e in ipairs(entries) do
        spawnPair(e)
    end
    for _, e in ipairs(fxEntries) do
        spawnPair(e)
    end

    -- Animated text pair
    local msdfAnimId = world:spawn(Transform(550, 1300, 0, WORLD_LAYER),
        Text(MSDF_FONT, "Smooth at any size", 1.0), Color(0.8, 0.9, 1, 1))
    local bitmapAnimId = world:spawn(Transform(550, 1300, 0, WORLD_LAYER),
        Text(BITMAP_FONT, "Smooth at any size", 1.0 * BITMAP_SCALE_FACTOR), Color(0.8, 0.9, 1, 1))
    table.insert(pairs, { msdfId = msdfAnimId, bitmapId = bitmapAnimId, sx = 1, sy = 1 } as EntityPair)
    local animPairIdx <const> = #pairs

    -- HUD (world-space, repositioned by camera system)
    local hudBarId = world:spawn(Transform(0, 0, 0, WORLD_LAYER),
        gfx.Rectangle(1400, 40), Color(0.1, 0.12, 0.16, 0.9))
    local hudTextId = world:spawn(Transform(0, 0, 1, WORLD_LAYER),
        Text(MSDF_FONT, "WASD:Pan  +/-:Zoom  0:Reset  []:Scale  TAB:Mode (MSDF)", 0.7),
        Color(0.65, 0.7, 0.8, 1), Pivot(0, 0))

    local showMSDF = true
    local initialized = false

    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.First,
        run = function()
            -- On first frame after spawn, hide bitmap entities
            if not initialized then
                initialized = true
                for _, p in ipairs(pairs) do
                    local t = world:getMut(p.bitmapId, Transform)
                    if t then t.scaleX = 0; t.scaleY = 0 end
                end
                return
            end

            local dt = love.timer.getDelta()
            local cam = pipeline:getCamera()

            -- WASD: pan
            local dx, dy = 0.0, 0.0
            local zoom = cam:getZoom()
            local speed = CAMERA_SPEED / zoom
            if input.isKeyDown("w") then dy = dy - speed * dt end
            if input.isKeyDown("s") then dy = dy + speed * dt end
            if input.isKeyDown("a") then dx = dx - speed * dt end
            if input.isKeyDown("d") then dx = dx + speed * dt end
            if dx ~= 0 or dy ~= 0 then
                local cx, cy = cam:getPosition()
                cam:setPosition(cx + dx, cy + dy)
            end

            -- +/-: zoom
            if input.isKeyDown("=") or input.isKeyDown("kp+") then
                cam:setZoom(min(zoom * (1 + ZOOM_SPEED * dt), 20))
            end
            if input.isKeyDown("-") or input.isKeyDown("kp-") then
                cam:setZoom(max(zoom * (1 - ZOOM_SPEED * dt), 0.05))
            end
            if input.isKeyPressed("0") then
                cam:setZoom(1.0)
                cam:setPosition(550, 400)
            end

            -- []: scale all visible text
            local scaleMul = 1.0
            if input.isKeyPressed("]") then scaleMul = 1.25 end
            if input.isKeyPressed("[") then scaleMul = 0.8 end
            if scaleMul ~= 1.0 then
                for _, p in ipairs(pairs) do
                    p.sx = p.sx * scaleMul
                    p.sy = p.sy * scaleMul
                    local activeId = showMSDF and p.msdfId or p.bitmapId
                    local t = world:getMut(activeId, Transform)
                    if t then
                        t.scaleX = p.sx
                        t.scaleY = p.sy
                    end
                end
            end

            -- TAB: toggle MSDF / bitmap
            if input.isKeyPressed("tab") then
                showMSDF = not showMSDF
                for _, p in ipairs(pairs) do
                    local hideId = showMSDF and p.bitmapId or p.msdfId
                    local showId = showMSDF and p.msdfId or p.bitmapId
                    local ht = world:getMut(hideId, Transform)
                    if ht then ht.scaleX = 0; ht.scaleY = 0 end
                    local st = world:getMut(showId, Transform)
                    if st then st.scaleX = p.sx; st.scaleY = p.sy end
                end

                local label = showMSDF and "MSDF" or "Bitmap"
                local txt = world:get(hudTextId, Text)
                if txt then
                    txt:setText("WASD:Pan +/-:Zoom 0:Reset []:Scale TAB:Mode (" .. label .. ")")
                end
            end

            -- Position HUD at bottom of camera view
            local cx, cy = cam:getPosition()
            local halfW = 640 / zoom
            local halfH = 360 / zoom
            local hudScale = 1 / zoom
            local barT = world:getMut(hudBarId, Transform)
            if barT then
                barT.x = cx
                barT.y = cy + halfH - 20 * hudScale
                barT.scaleX = hudScale
                barT.scaleY = hudScale
            end
            local txtT = world:getMut(hudTextId, Transform)
            if txtT then
                txtT.x = cx - halfW + 10 * hudScale
                txtT.y = cy + halfH - 38 * hudScale
                txtT.scaleX = hudScale
                txtT.scaleY = hudScale
            end
        end
    })

    -- Pulse the animated text
    world:addSystem({
        name = "AnimateScale",
        phase = tecs.phases.Update,
        run = function()
            if not initialized then return end
            local p = pairs[animPairIdx]
            local s = 1.5 + sin(love.timer.getTime() * 1.5) * 1.0
            p.sx = s
            p.sy = s
            local activeId = showMSDF and p.msdfId or p.bitmapId
            local t = world:getMut(activeId, Transform)
            if t then t.scaleX = s; t.scaleY = s end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    render = {
        lightingMode = "none",
        layers = {
            [1] = { name = "world" },
        },
    },
    game = function(world: tecs.World)
        examplePlugin(world)
    end,
})
