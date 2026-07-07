--- Static sprite steady state: a large grid of animated sprites sharing
--- one sheet. Animation is GPU-timed, so after setup no CPU-side sprite
--- state changes; this measures per-frame bucket sync, material walks,
--- and cull dispatch overhead.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")
local SpriteSheet = require("tecs2d.gfx.internal.sprite.sheet").SpriteSheet
local spriteModule = require("tecs2d.gfx.internal.sprite")

local Transform = tecs.builtins.Transform

local SPRITES = 20000

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
        cameraPosition = {0, 0},
        sizeHints = {sprites = SPRITES + 64},
    },
    meta = {sprites = SPRITES},
    setup = function(world)
        local pipeline = world.resources[gfx.PIPELINE]
        local runnerSheet = SpriteSheet.fromFile("assets/running.png")
        local sharedStartTime = pipeline:getTime()
        local probe = gfx.Sprite.fromSheet(runnerSheet, "run", {
            centered = true,
            startTime = sharedStartTime,
        })
        local sharedSpriteId = probe.spriteId

        local gridSize = math.ceil(math.sqrt(SPRITES))
        local spacing = 40
        local startX = -((gridSize - 1) * spacing) / 2
        local startY = -((gridSize - 1) * spacing) / 2
        local SpriteComponent = spriteModule.Sprite

        world:batchSpawn(SPRITES,
            {Transform, SpriteComponent},
            function(arch, startRow, lastRow)
                local transforms = arch:getMut(Transform)
                local sprites = arch:getMut(SpriteComponent)
                for i = startRow, lastRow do
                    local idx = i - startRow
                    local row = math.floor(idx / gridSize)
                    local col = idx % gridSize
                    local t = transforms[i]
                    t.x = startX + (col * spacing)
                    t.y = startY + (row * spacing)
                    t.z = idx * 0.001
                    t.layer = 2
                    t.rotation = 0
                    t.scaleX = 1
                    t.scaleY = 1

                    local s = sprites[i]
                    s.spriteId = sharedSpriteId
                    s.animStartTime = sharedStartTime
                    s.pausedFrame = -1
                    s._pauseAtFrame = -1
                    s.pauseDepth = 0
                end
            end)
    end,
}
