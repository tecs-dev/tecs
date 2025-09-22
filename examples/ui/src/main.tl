--- Tecs UI Examples
--- Cycle through examples with left/right arrow keys

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local ui <const> = require("tecs2d.ui")
local mcp <const> = require("tecs2d.mcp")

-- Scene modules
local common <const> = require("scenes.common")
local originScene <const> = require("scenes.origin")
local dynamicScene <const> = require("scenes.dynamic")
local scrollableScene <const> = require("scenes.scrollable")
local helpersScene <const> = require("scenes.helpers")

local lg <const> = love.graphics

local LayoutNode <const> = ui.LayoutNode
local LayoutBox <const> = ui.LayoutBox
local Anchor <const> = ui.Anchor
local Text <const> = gfx.Text
local Transform <const> = tecs.builtins.Transform

local WINDOW_WIDTH <const>, WINDOW_HEIGHT <const> = 1280, 768

-- Scene management
local scenes: {common.Scene} = {}
local currentSceneIndex = 1
local sceneEntities: {integer} = {}

-- Helper to clear current scene entities
local function clearScene(world: tecs.World)
    for _, entityId in ipairs(sceneEntities) do
        if world:isAlive(entityId) then
            world:despawn(entityId)
        end
    end
    sceneEntities = {}
end

-- Helper to track spawned entity
local function spawn(world: tecs.World, ...: tecs.Component): integer
    local id = world:spawn(...)
    sceneEntities[#sceneEntities + 1] = id
    return id
end

--------------------------------------------------------------------------------
-- Main Plugin
--------------------------------------------------------------------------------
local function tecsUiExamplePlugin(world: tecs.World)
    -- Set light background color
    lg.setBackgroundColor(0.12, 0.12, 0.14)

    world:addPlugin(mcp.new())

    -- Register scenes
    scenes = {
        originScene as common.Scene,
        dynamicScene as common.Scene,
        scrollableScene as common.Scene,
        helpersScene as common.Scene
    }

    -- Setup initial scene
    scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)

    -- Navigation and scroll handling
    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.Update,
        run = function(_dt: number)
            -- Scene navigation
            -- Force commit between despawns and spawns to avoid transaction conflicts
            if input.isKeyPressed("right") then
                clearScene(world)
                world:commit()  -- Commit despawns before spawning new entities
                currentSceneIndex = currentSceneIndex % #scenes + 1
                scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
            elseif input.isKeyPressed("left") then
                clearScene(world)
                world:commit()  -- Commit despawns before spawning new entities
                currentSceneIndex = (currentSceneIndex - 2) % #scenes + 1
                scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
            end

            -- Scroll handling for scroll scene
            local scrollContainer = world.resources["scrollContainer" as tecs.Key<integer>]
            if scrollContainer and world:isAlive(scrollContainer) then
                local layoutNode = world:get(scrollContainer, LayoutNode)
                local layoutBox = world:get(scrollContainer, LayoutBox)
                if layoutNode and layoutBox then
                    local scrollDelta = 0.0
                    local dt = love.timer.getDelta()
                    if input.isKeyDown("down") then
                        scrollDelta = 300.0 * dt
                    elseif input.isKeyDown("up") then
                        scrollDelta = -300.0 * dt
                    end

                    local _, wheelY = input.getMouseWheelMovement()
                    if wheelY ~= 0 then
                        scrollDelta = scrollDelta - wheelY * 40.0
                    end

                    if scrollDelta ~= 0 then
                        layoutNode.scrollY = layoutNode.scrollY + scrollDelta
                        local maxScroll = math.max(0, layoutNode.contentHeight - layoutBox.height)
                        layoutNode.scrollY = math.max(0, math.min(layoutNode.scrollY, maxScroll))
                    end
                end
            end

            if input.isKeyPressed("escape") then
                love.event.quit()
            end
        end
    })

    -- Scene indicator using Text (Dracula green), anchored to bottom-center
    local indicatorText = string.format("< %d/%d: %s >", currentSceneIndex, #scenes, scenes[currentSceneIndex].name)
    local indicatorId = world:spawn(
        Transform(0, 0, 100),
        Anchor(0.5, 1, 0, -35),
        Text(common.DEFAULT_FONT, indicatorText, 1.0),
        LayoutBox(Text),
        gfx.Color(0.31, 0.98, 0.48)  -- Dracula green
    )

    world:addSystem({
        name = "UpdateSceneIndicator",
        phase = tecs.phases.Update,
        run = function()
            if world:isAlive(indicatorId) then
                local txt = world:get(indicatorId, Text)
                if txt then
                    local newText = string.format("< %d/%d: %s >", currentSceneIndex, #scenes, scenes[currentSceneIndex].name)
                    txt:setText(newText)
                end
            end
        end
    })

    -- Animation system for Dynamic Dimensions scene
    local animTime = 0.0
    local textVariants = {"Hi!", "Hello!", "Greetings!", "Hey!", "Howdy!"}
    local fitTextVariants = {"Fit!", "Auto-size!", "FitContent!", "Dynamic!", "Grows!"}
    local lastTextIndex = 1
    local lastFitTextIndex = 1
    world:addSystem({
        name = "AnimateDynamicScene",
        phase = tecs.phases.Update,
        run = function(dt: number)
            animTime = animTime + dt

            local rectId = world.resources["dynamicRect" as tecs.Key<integer>]
            local circleId = world.resources["dynamicCircle" as tecs.Key<integer>]
            local textId = world.resources["dynamicText" as tecs.Key<integer>]

            if rectId and world:isAlive(rectId) then
                local rect = world:get(rectId, gfx.Rectangle)
                if rect then
                    -- Animate rectangle size with sine wave
                    rect.width = 80.0 + math.sin(animTime * 2) * 40.0
                    rect.height = 50.0 + math.cos(animTime * 1.5) * 30.0
                end
            end

            if circleId and world:isAlive(circleId) then
                local circle = world:get(circleId, gfx.Circle)
                if circle then
                    -- Animate circle radius
                    circle.radius = 35.0 + math.sin(animTime * 2.5) * 20.0
                end
            end

            if textId and world:isAlive(textId) then
                -- Change text every 2 seconds
                local textIndex = (math.floor(animTime / 2) % #textVariants) + 1
                if textIndex ~= lastTextIndex then
                    lastTextIndex = textIndex
                    local txt = world:get(textId, Text)
                    if txt then
                        txt:setText(textVariants[textIndex])
                    end
                end
            end

            -- Animate FitContent text (changes text, container auto-resizes)
            local fitTextId = world.resources["fitText" as tecs.Key<integer>]
            local fitContainerId = world.resources["fitContainer" as tecs.Key<integer>]
            local fitBorderId = world.resources["fitBorder" as tecs.Key<integer>]

            if fitTextId and world:isAlive(fitTextId) then
                local fitTextIndex = (math.floor(animTime / 1.5) % #fitTextVariants) + 1
                if fitTextIndex ~= lastFitTextIndex then
                    lastFitTextIndex = fitTextIndex
                    local txt = world:get(fitTextId, Text)
                    if txt then
                        txt:setText(fitTextVariants[fitTextIndex])
                    end
                end
            end

            -- Sync border size with container (FitContent updates container's Rectangle)
            if fitContainerId and fitBorderId and world:isAlive(fitContainerId) and world:isAlive(fitBorderId) then
                local containerRect = world:get(fitContainerId, gfx.Rectangle)
                local borderRect = world:get(fitBorderId, gfx.Rectangle)
                if containerRect and borderRect then
                    borderRect.width = containerRect.width
                    borderRect.height = containerRect.height
                end
            end
        end
    })
end


love.run = tecs2d.run({
    fps = 60,
    game = tecsUiExamplePlugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2},
        layers = {
            [1] = { name = "background" },
            [2] = { name = "ui" },
        },
    },
})
