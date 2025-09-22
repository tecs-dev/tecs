local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")
local input <const> = require("tecs2d.input")

local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"


local WINDOW_HEIGHT <const> = 600
local sin, cos, sqrt, atan2 <const> = math.sin, math.cos, math.sqrt, math.atan2

local MIN_ORBIT_RADIUS <const> = 100
local SPIRAL_FACTOR <const> = 2
local ORBIT_SPEED <const> = 1.0
local PARENT_ROTATION_SPEED <const> = 0.5
local MIN_SATELLITES <const> = 100
local MAX_SATELLITES <const> = 500000

local Transform <const> = tecs.builtins.Transform
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local ChildOf <const> = tecs.builtins.ChildOf

local record DemoState
    centerCircle: integer
    numSatellites: integer
    satelliteCountText: integer
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<DemoState>

-- Calculate position for a satellite based on entity ID
local function calculateSatellitePosition(entityId: integer): number, number
    local angle = entityId * SPIRAL_FACTOR
    local radius = MIN_ORBIT_RADIUS + sqrt(entityId) * 80
    local offsetX = cos(angle) * radius
    local offsetY = sin(angle) * radius
    return offsetX, offsetY
end

local function createSatellite(world: tecs.World, centerCircle: integer): integer
    local relativeTransform = RelativeTransform(0, 0, 0, 0, 1, 1)
    local color = gfx.Color(1.0, 0.0, 0.0, 1.0)
    local satId = world:spawn(
        ChildOf(centerCircle) as tecs.Component,
        relativeTransform,
        gfx.Rectangle(20, 20),
        color
    )

    -- Set position based on entity ID
    local offsetX, offsetY = calculateSatellitePosition(satId)
    relativeTransform.x, relativeTransform.y = offsetX, offsetY

    -- Color gradient based on distance from center (fiery: yellow -> orange -> red)
    local radius = sqrt(offsetX * offsetX + offsetY * offsetY)
    local normalizedRadius = (radius - MIN_ORBIT_RADIUS) / 2000.0           -- Normalize to ~0-1 range
    normalizedRadius = normalizedRadius > 1.0 and 1.0 or normalizedRadius   -- Clamp to max 1.0

    -- Yellow (close) -> Orange -> Red (far)
    color.r = 1.0
    color.g = 1.0 - normalizedRadius * 0.7      -- 1.0 -> 0.3
    color.b = (1.0 - normalizedRadius) * 0.6    -- 0.6 -> 0.0

    return satId
end

local SPAWN_BATCH_SIZE <const> = 100

local function addSatellites(world: tecs.World, state: DemoState, count: integer)
    local toSpawn = count
    if state.numSatellites + toSpawn > MAX_SATELLITES then
        toSpawn = MAX_SATELLITES - state.numSatellites
    end
    if toSpawn <= 0 then return end

    local centerCircle = state.centerCircle
    local firstSatId = 0
    local lastSatId = 0
    for i = 1, toSpawn do
        local id = world:spawn(
            ChildOf(centerCircle) as tecs.Component,
            RelativeTransform(0, 0, 0, 0, 1, 1),
            gfx.Rectangle(20, 20),
            gfx.Color(1.0, 0.0, 0.0, 1.0)
        )
        if i == 1 then firstSatId = id end
        lastSatId = id
    end
    world:commit()

    -- Set positions and colors based on entity IDs
    for satId = firstSatId, lastSatId do
        local offsetX, offsetY = calculateSatellitePosition(satId)
        local rt = world:get(satId, RelativeTransform)
        if rt then
            rt.x, rt.y = offsetX, offsetY
        end
        local color = world:get(satId, gfx.Color)
        if color then
            local radius = sqrt(offsetX * offsetX + offsetY * offsetY)
            local normalizedRadius = (radius - MIN_ORBIT_RADIUS) / 2000.0
            normalizedRadius = normalizedRadius > 1.0 and 1.0 or normalizedRadius
            color.r = 1.0
            color.g = 1.0 - normalizedRadius * 0.7
            color.b = (1.0 - normalizedRadius) * 0.6
        end
    end

    state.numSatellites = state.numSatellites + toSpawn
end

-- Remove one satellite
local function removeSatellite(world: tecs.World, state: DemoState, satelliteQuery: tecs.Query)
    if state.numSatellites > 0 then
        for _, len, entities in satelliteQuery:iter() do
            if len > 0 then
                world:despawn(entities[1])
                state.numSatellites = state.numSatellites - 1
                return
            end
        end
    end
end

-- Game plugin function that sets up the world
local function orbitingShapesPlugin(world: tecs.World)
    -- Add stats plugin for debug info
    world:addPlugin(stats.newStatsPlugin())
    world:addPlugin(mcp.new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    local centerCircle = world:spawn(
        Transform(0, 0, 0, 1, 0, 1, 1),
        gfx.Circle(30),
        gfx.Color(0.3, 0.6, 1.0, 1.0)
    )

    -- Spawn HUD text entities on layer 3 (virtual space)
    local satelliteCountText = world:spawn(
        Transform(20, WINDOW_HEIGHT - 70, 0, 3),
        Text(FONT_PATH, "Satellites: 0", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    world:spawn(
        Transform(20, WINDOW_HEIGHT - 50, 0, 3),
        Text(FONT_PATH, "UP/DOWN: Add/Remove satellites | -/=: Zoom", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    world:spawn(
        Transform(20, WINDOW_HEIGHT - 30, 0, 3),
        Text(FONT_PATH, "R: Rotate parent | S/D: Scale parent | ESC: Quit", 1),
        gfx.Color(0.6, 0.6, 0.6, 1),
        gfx.Pivot(0, 0)
    )

    local state: DemoState = {
        centerCircle = centerCircle,
        numSatellites = 0,
        satelliteCountText = satelliteCountText
    }
    world.resources[STATE_KEY] = state

    -- Spawn initial satellites in bulk
    addSatellites(world, state, MIN_SATELLITES)

    local satelliteQuery = world:query({
        name = "OrbitSatellites",
        include = {RelativeTransform}
    })

    world:addSystem({
        name = "OrbitSatellites",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local angleDelta = ORBIT_SPEED * dt
            local maxSatellites = 0 -- spawn satellites if below desired count

            for archetype, len in satelliteQuery:iter() do
                maxSatellites = maxSatellites + len
                local relTransforms = archetype:getMut(RelativeTransform)
                for row = 1, len do
                    local rt = relTransforms[row]
                    -- Rotate the offset vector to make satellites orbit
                    local currentAngle = atan2(rt.y, rt.x)
                    local radius = sqrt(rt.x * rt.x + rt.y * rt.y)
                    local newAngle = currentAngle + angleDelta
                    rt.x = cos(newAngle) * radius
                    rt.y = sin(newAngle) * radius
                end
            end

            if maxSatellites < state.numSatellites then
                createSatellite(world, state.centerCircle)
            end
        end
    })

    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.First,
        run = function()
            if input.isKeyPressed("escape") then
                love.event.quit()
            end

            if input.isKeyDown("up") then
                if state.numSatellites < MAX_SATELLITES then
                    addSatellites(world, state, SPAWN_BATCH_SIZE)
                end
            elseif input.isKeyDown("down") and state.numSatellites > MIN_SATELLITES then
                removeSatellite(world, state, satelliteQuery)
            end

            local cam = pipeline:getCamera()
            if input.isKeyDown("=") then
                cam:setZoom(cam:getZoom() * 1.1)
            elseif input.isKeyDown("-") then
                -- Slow down zoom-out as zoom gets smaller (squared for more aggressive slowdown)
                local currentZoom = cam:getZoom()
                local t = math.min(currentZoom, 1.0)
                local zoomOutFactor = 1.0 + 0.1 * t * t
                local newZoom = math.max(currentZoom / zoomOutFactor, 0.02)
                cam:setZoom(newZoom)
            end

            -- Move center circle with mouse
            local worldX, worldY = cam:toWorld(input.mouseX, input.mouseY)

            local centerTransform = world:get(state.centerCircle, Transform)
            if centerTransform then
                centerTransform.x = worldX
                centerTransform.y = worldY
            end
        end
    })

    world:addSystem({
        name = "RotateAndScaleParent",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local centerTransform = world:get(state.centerCircle, Transform)
            if centerTransform then
                -- Rotate parent with R key
                if input.isKeyDown("r") then
                    centerTransform.rotation = centerTransform.rotation + PARENT_ROTATION_SPEED * dt
                end

                -- Scale parent with S/D keys
                if input.isKeyDown("s") then
                    local newScale = centerTransform.scaleX * 1.02
                    centerTransform.scaleX = newScale
                    centerTransform.scaleY = newScale
                elseif input.isKeyDown("d") then
                    local newScale = centerTransform.scaleX / 1.02
                    centerTransform.scaleX = newScale
                    centerTransform.scaleY = newScale
                end
            end
        end
    })

    -- Track last displayed count for efficient updates
    local lastDisplayedCount = 0

    world:addSystem({
        name = "UpdateHUD",
        phase = tecs.phases.Update,
        run = function()
            if state.numSatellites ~= lastDisplayedCount then
                lastDisplayedCount = state.numSatellites
                local text = world:get(state.satelliteCountText, Text)
                if text then
                    text:setText("Satellites: " .. tostring(state.numSatellites))
                end
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    game = orbitingShapesPlugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        layers = {
            [1] = { name = "background" },
            [2] = { name = "shapes" },
            [3] = { name = "hud", space = "virtual" },
        },
    },
})
