--- Tecs Audio Example: Spatial audio demo with procedural sounds and icons.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local audio <const> = require("tecs2d.audio")
local tecs_assets <const> = require("tecs2d.assets")
local mcp <const> = require("tecs2d.mcp")
local icons <const> = require("icons")
local sounds <const> = require("sounds")

local lg <const> = love.graphics
local la <const> = love.audio
local sqrt <const> = math.sqrt
local sin <const> = math.sin

local PLAYER_SPEED <const> = 300
local WORLD_SIZE <const> = 1000
local ICON_SCALE <const> = 4
local VIRTUAL_HEIGHT <const> = 1000
local FONT_PATH <const> = "assets/press-start-2p.fnt"

local Transform <const> = tecs.builtins.Transform
local Text <const> = gfx.Text

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local record SoundEmitter is tecs.Component
    name: string
    icon: love.graphics.Image
    metamethod __call: function(self, data: {string:any}): SoundEmitter
end

-- Icon and sound lookup tables, populated once by the plugin. Used by
-- SoundEmitter's deserialize to rebuild procedural assets by name.
local iconsByName: {string: love.graphics.Image} = {}

tecs.newComponent({
    name = "SoundEmitter",
    container = SoundEmitter,
    new = function(data: {string:any}): SoundEmitter
        return data as SoundEmitter
    end,
    serialize = function(e: SoundEmitter): {string: any}
        return {name = e.name}
    end,
    deserialize = function(_world: tecs.World, data: {string: any}): SoundEmitter
        if not data then return nil end
        local name = data.name as string
        return SoundEmitter.new({name = name, icon = iconsByName[name]})
    end,
})

local record PlayerComponent is tecs.Component
    metamethod __call: function(self): PlayerComponent
end

local Player <const> = tecs.newTagComponent({ name = "Player" }) as PlayerComponent

-------------------------------------------------------------------------------
-- Game
-------------------------------------------------------------------------------

local function audioExamplePlugin(world: tecs.World)
    world:addPlugin(require("tecs2d.stats").newStatsPlugin())
local input <const> = require("tecs2d.input")

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Load assets
    local img = icons.load()
    local snd = sounds.load()

    -- Populate icon lookup for SoundEmitter deserialize
    iconsByName["Bass"]    = img.guitar
    iconsByName["Drums"]   = img.drum
    iconsByName["Speaker"] = img.speaker
    iconsByName["Keys"]    = img.keyboard

    local assets = world.resources[tecs_assets] as tecs_assets.AssetManager
    local audioManager = world.resources[audio]

    -- Spawn emitters. AudioSource uses real asset handles (file paths) so
    -- snapshots round-trip automatically; no FinishSnapshotLoad needed.
    local emitterDefs: {{number, number, string, string, love.graphics.Image}} = {
        {-350, -300, snd.bassline, "Bass", img.guitar},
        {350, -300, snd.drum, "Drums", img.drum},
        {350, 300, snd.pad, "Speaker", img.speaker},
        {0, 0, snd.keyboard, "Keys", img.keyboard},
    }

    for _, e in ipairs(emitterDefs) do
        world:spawn(
            Transform(e[1], e[2], 0, 1),
            SoundEmitter({name = e[4], icon = e[5]}),
            audio.AudioSource.new({
                handle = assets:loadAudio(e[3], "static"),
                group = "sfx",
                looping = true,
                playing = true,
                refDistance = 80,
                maxDistance = 600,
            })
        )
    end

    -- Spawn player
    world:spawn(
        Transform(0, -100, 0, 1),
        audio.AudioListener(),
        Player()
    )

    -- Spawn HUD text entities on layer 3 (virtual space)
    world:spawn(
        Transform(10, VIRTUAL_HEIGHT - 20, 0, 3),
        Text(FONT_PATH, "WASD: Move | M: Mute | +/-: Volume | P: Pause | R: Reverb | ESC: Quit", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    local volumeStatusText = world:spawn(
        Transform(10, VIRTUAL_HEIGHT - 38, 0, 3),
        Text(FONT_PATH, "Volume: 80%", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    world:spawn(
        Transform(10, VIRTUAL_HEIGHT - 56, 0, 3),
        Text(FONT_PATH, "Move closer to icons to hear them louder!", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    -- Spawn emitter distance text entities (one per emitter)
    local emitterTextEntities: {integer} = {}
    local emitterOrder = {"Keys", "Speaker", "Drums", "Bass"}
    for i, _ in ipairs(emitterOrder) do
        local textEntity = world:spawn(
            Transform(10, VIRTUAL_HEIGHT - 79 - (i - 1) * 18, 0, 3),
            Text(FONT_PATH, "", 1),
            gfx.Color(1, 1, 1, 1),
            gfx.Pivot(0, 0)
        )
        emitterTextEntities[i] = textEntity
    end

    local playerQuery = world:query({ name = "Player", include = {Player, Transform} })
    local emitterQuery = world:query({ name = "Emitters", include = {SoundEmitter, Transform} })

    -- Player movement
    world:addSystem({
        name = "PlayerMovement",
        phase = tecs.phases.Update,
        run = function(dt: number)
            for archetype, len in playerQuery:iter() do
                local transforms = archetype:getMut(Transform)
                for i = 1, len do
                    local t = transforms[i]
                    local dx: number = 0
                    local dy: number = 0
                    if input.isKeyDown("w") or input.isKeyDown("up") then dy = -1 end
                    if input.isKeyDown("s") or input.isKeyDown("down") then dy = 1 end
                    if input.isKeyDown("a") or input.isKeyDown("left") then dx = -1 end
                    if input.isKeyDown("d") or input.isKeyDown("right") then dx = 1 end

                    if dx ~= 0 and dy ~= 0 then
                        local d = sqrt(dx * dx + dy * dy)
                        dx, dy = dx / d, dy / d
                    end

                    t.x = t.x + dx * PLAYER_SPEED * dt
                    t.y = t.y + dy * PLAYER_SPEED * dt

                    local bound = WORLD_SIZE / 2 + 100
                    t.x = math.max(-bound, math.min(bound, t.x))
                    t.y = math.max(-bound, math.min(bound, t.y))
                end
            end
        end
    })

    -- Controls state
    local isMuted = false
    local masterVolume = 0.8
    local reverbEnabled = false
    la.setVolume(masterVolume)

    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.First,
        run = function()
            if input.isKeyPressed("escape") then love.event.quit() end

            -- Mute toggle
            if input.isKeyPressed("m") then
                isMuted = not isMuted
                la.setVolume(isMuted and 0 or masterVolume)
            end

            -- Volume up/down
            if input.isKeyPressed("=") or input.isKeyPressed("+") then
                masterVolume = math.min(1.0, masterVolume + 0.1)
                if not isMuted then la.setVolume(masterVolume) end
            end
            if input.isKeyPressed("-") then
                masterVolume = math.max(0.0, masterVolume - 0.1)
                if not isMuted then la.setVolume(masterVolume) end
            end

            -- Pause/resume with fade (P key)
            if input.isKeyPressed("p") then
                if audioManager:isGroupPaused("sfx") then
                    audioManager:resumeGroup("sfx", 0.5)
                else
                    audioManager:pauseGroup("sfx", 0.5)
                end
            end

            -- Toggle reverb effect (R key)
            if input.isKeyPressed("r") then
                reverbEnabled = not reverbEnabled
                if reverbEnabled then
                    audioManager:setGroupEffect("sfx", "reverb", { decaytime = 4.0, density = 1.0, diffusion = 1.0, gain = 0.5 })
                else
                    audioManager:removeGroupEffect("sfx", "reverb")
                end
            end
        end
    })

    -- Render icons in world space
    world:addSystem({
        name = "RenderIcons",
        phase = tecs.phases.Render,
        run = function()
            local playerX: number = 0
            local playerY: number = 0
            for archetype, len in playerQuery:iter() do
                local transforms = archetype:get(Transform)
                if len > 0 then playerX, playerY = transforms[1].x, transforms[1].y end
            end

            for archetype, len in emitterQuery:iter() do
                local transforms = archetype:get(Transform)
                local emitterData = archetype:get(SoundEmitter)

                for i = 1, len do
                    local t = transforms[i]
                    local emitter = emitterData[i]

                    local dx, dy = t.x - playerX, t.y - playerY
                    local distance = sqrt(dx * dx + dy * dy)

                    local alpha = 1.0 - ((distance - 80) / 520)
                    alpha = math.max(0.3, math.min(1.0, alpha))
                    alpha = alpha * (0.9 + 0.1 * sin(love.timer.getTime() * 4 + i))

                    lg.setColor(1, 1, 1, alpha)
                    local screenX, screenY = pipeline:getCamera():toScreen(t.x, t.y)
                    local offset = 8 * ICON_SCALE
                    lg.draw(emitter.icon as love.graphics.Drawable, screenX - offset, screenY - offset, 0, ICON_SCALE, ICON_SCALE)
                end
            end

            lg.setColor(1, 1, 1, 1)
            local screenX, screenY = pipeline:getCamera():toScreen(playerX, playerY)
            local offset = 8 * ICON_SCALE
            lg.draw(img.smiley as love.graphics.Drawable, screenX - offset, screenY - offset, 0, ICON_SCALE, ICON_SCALE)
        end
    })

    -- Update HUD text
    world:addSystem({
        name = "UpdateHUD",
        phase = tecs.phases.Update,
        run = function()
            local playerX: number = 0
            local playerY: number = 0
            for archetype, len in playerQuery:iter() do
                local transforms = archetype:get(Transform)
                if len > 0 then playerX, playerY = transforms[1].x, transforms[1].y end
            end

            -- Update volume status text
            local mutedText = isMuted and " (MUTED)" or ""
            local pausedText = audioManager:isGroupPaused("sfx") and " (PAUSED)" or ""
            local reverbText = reverbEnabled and " [REVERB]" or ""
            local volumeText = world:get(volumeStatusText, Text)
            if volumeText then
                volumeText:setText(string.format("Volume: %.0f%%%s%s%s", masterVolume * 100, mutedText, pausedText, reverbText))
            end

            -- Build emitter distances sorted by name to match emitterOrder
            local emitterDistances: {string:number} = {}
            for archetype, len in emitterQuery:iter() do
                local transforms = archetype:get(Transform)
                local emitterData = archetype:get(SoundEmitter)
                for i = 1, len do
                    local t = transforms[i]
                    local emitter = emitterData[i]
                    local dx, dy = t.x - playerX, t.y - playerY
                    emitterDistances[emitter.name] = sqrt(dx * dx + dy * dy)
                end
            end

            -- Update emitter distance texts
            for i, name in ipairs(emitterOrder) do
                local distance = emitterDistances[name] or 0
                local text = world:get(emitterTextEntities[i], Text)
                if text then
                    text:setText(string.format("%s: %.0f units", name, distance))
                end
            end
        end
    })

end


love.run = tecs2d.run({
    fps = 60,
    game = function(world: tecs.World)
        world:addPlugin(mcp.new())
        local audioManager = world.resources[audio]
        audioManager:setGroupVolume("sfx", 0.8)
        audioManager:setGroupVolume("music", 0.7)
        audioExamplePlugin(world)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        layers = {
            [1] = { name = "background" },
            [2] = { name = "icons" },
            [3] = { name = "hud", space = "virtual" },
        },
    },
})
