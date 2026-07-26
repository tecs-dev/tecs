--- A scripted boss encounter that survives a save mid-cutscene.
---
--- The whole encounter is one `tecs2d.sequence` program: the boss walks in
--- while the banner drops (a `parallel` of two tweens), adds spawn, the
--- sequence blocks on a query until they are all dead, then phase two plays
--- and the encounter ends. Nothing about it is a coroutine, so saving in the
--- middle and loading again resumes at the same instruction.
---
--- Controls:
---   Space   kill one add
---   S       save    L  load
---   P       pause / resume the encounter
---   R       restart the encounter
---   X       cancel the encounter
---   Esc     quit

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local sequence <const> = require("tecs2d.sequence")
local tween <const> = require("tecs2d.tween")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("sequence-demo")

local Transform <const> = tecs.builtins.Transform

local WINDOW_WIDTH <const> = 900
local WINDOW_HEIGHT <const> = 560

local ARENA_LAYER <const> = 1
local HUD_LAYER <const> = 16

local SAVE_PATH <const> = "encounter.save"
local FONT <const> = "assets/press-start-2p.fnt"

local BOSS_START_X <const> = WINDOW_WIDTH + 80
local BOSS_HOME_X <const> = WINDOW_WIDTH / 2
local BANNER_HIDDEN_Y <const> = -60
local BANNER_SHOWN_Y <const> = 96

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local record Add is tecs.Component
    metamethod __call: function(self): Add
end
tecs.newTagComponent({name = "SequenceDemoAdd", container = Add})

local record HudSlot is tecs.Component
    role: string
    metamethod __call: function(self, role: string): HudSlot
end
tecs.newComponent({
    name = "SequenceDemoHudSlot",
    container = HudSlot,
    fields = {"role"},
})

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local function plugin(world: tecs.World)
    love.graphics.setBackgroundColor(0.06, 0.07, 0.10)

    local encounter: sequence.Handle = nil
    local boss = 0
    local banner = 0
    local status = "Encounter running."
    local addsKilled = 0

    local addQuery = world:query({name = "DemoAdds", include = {Add}})
    local hudQuery = world:query({name = "DemoHud", include = {HudSlot, gfx.Text}})

    ---------------------------------------------------------------------------
    -- Scene
    ---------------------------------------------------------------------------

    local function spawnActors()
        boss = world:spawn(
            Transform.new({x = BOSS_START_X, y = 300, layer = ARENA_LAYER}),
            gfx.Rectangle(120, 160),
            gfx.Color(0.75, 0.22, 0.30, 1)
        )
        banner = world:spawn(
            Transform.new({x = WINDOW_WIDTH / 2, y = BANNER_HIDDEN_Y, layer = ARENA_LAYER}),
            gfx.Rectangle(520, 52),
            gfx.Color(0.16, 0.18, 0.30, 1)
        )
    end

    local function spawnHud()
        local function line(y: number, role: string, size: number, alpha: number)
            world:spawn(
                Transform.new({x = 20, y = y, layer = HUD_LAYER}),
                gfx.Text(FONT, "", size),
                gfx.Color(1, 1, 1, alpha),
                gfx.Pivot(0, 0),
                HudSlot(role)
            )
        end
        world:spawn(
            Transform.new({x = 20, y = 14, layer = HUD_LAYER}),
            gfx.Text(FONT, "Tecs Sequence", 1.1),
            gfx.Color(1, 1, 1, 1),
            gfx.Pivot(0, 0)
        )
        line(44, "status", 0.8, 0.95)
        line(66, "cursor", 0.8, 0.8)
        line(88, "adds", 0.8, 0.8)
        world:spawn(
            Transform.new({x = 20, y = WINDOW_HEIGHT - 28, layer = HUD_LAYER}),
            gfx.Text(FONT, "Space kill add  S save  L load  P pause  R restart  X cancel  Esc", 0.7),
            gfx.Color(0.75, 0.78, 0.85, 1),
            gfx.Pivot(0, 0)
        )
    end

    local function countAdds(): integer
        local n = 0
        for _, len in addQuery:iter() do n = n + len end
        return n
    end

    local function despawnAdds()
        local ids: {integer} = {}
        for archetype, len in addQuery:iter() do
            local entities = archetype.entities as {integer}
            for i = 1, len do ids[#ids + 1] = entities[i] end
        end
        for i = 1, #ids do world:despawn(ids[i]) end
    end

    ---------------------------------------------------------------------------
    -- The pieces the program names
    ---------------------------------------------------------------------------

    -- A query the sequence blocks on: "wait until no adds remain".
    sequence.registerQuery(world, "demo.adds", {include = {Add}})

    tween.registerPreset(world, "demo.bossWalkIn", tween.timeline({
        tween.to(1.6, tween.quadOut, tween.translateX, BOSS_HOME_X),
    }))
    tween.registerPreset(world, "demo.bannerDrop", tween.timeline({
        tween.to(0.9, tween.quadOut, tween.translateY, BANNER_SHOWN_Y),
    }))
    tween.registerPreset(world, "demo.bossEnrage", tween.timeline({
        tween.to(0.35, tween.quadOut, tween.scaleXY, 1.25, 1.25),
        tween.to(0.35, tween.quadIn, tween.scaleXY, 1.0, 1.0),
    }))

    sequence.registerAction(world, "demo.announce",
        function(_w: tecs.World, ctx: sequence.ActionContext)
        status = ctx.args[1] as string
        LOGGER:info("%s", status)
    end)

    sequence.registerAction(world, "demo.spawnAdds",
        function(w: tecs.World, ctx: sequence.ActionContext)
        local count = ctx.args[1] as integer
        for i = 1, count do
            local angle = (i / count) * math.pi * 2
            w:spawn(
                Transform.new({
                    x = BOSS_HOME_X + math.cos(angle) * 190,
                    y = 300 + math.sin(angle) * 110,
                    layer = ARENA_LAYER,
                }),
                gfx.Circle(22),
                gfx.Color(0.95, 0.72, 0.25, 1),
                Add()
            )
        end
    end)

    ---------------------------------------------------------------------------
    -- The encounter
    ---------------------------------------------------------------------------

    local encounterProgram <const> = sequence.define("demo.bossEncounter", {
        sequence.call("demo.announce", "The boss approaches."),
        -- Two things move at once, and the encounter waits for both.
        sequence.parallel(
            {
                sequence.playTween("demo.bossWalkIn", sequence.bind("boss")),
                sequence.waitTween(),
            },
            {
                sequence.playTween("demo.bannerDrop", sequence.bind("banner")),
                sequence.waitTween(),
            }
        ),
        sequence.call("demo.announce", "Adds incoming."),
        sequence.wait(0.6),
        sequence.call("demo.spawnAdds", 5),
        sequence.emit("demo.addsSpawned"),
        -- A condition on the world, not an edge: this resumes when the last
        -- add dies, whoever killed it.
        sequence.waitQuery("demo.adds", "empty"),
        sequence.call("demo.announce", "Phase two."),
        sequence.loop(2, {
            sequence.playTween("demo.bossEnrage", sequence.bind("boss")),
            sequence.waitTween(),
        }),
        sequence.emit("demo.encounterCleared"),
        sequence.call("demo.announce", "Encounter cleared. R restarts it."),
    })

    local function startEncounter()
        if encounter then sequence.cancel(world, encounter) end
        despawnAdds()
        addsKilled = 0
        if world:isAlive(boss) then world:despawn(boss) end
        if world:isAlive(banner) then world:despawn(banner) end
        world:commit()
        spawnActors()
        encounter = sequence.play(world, encounterProgram, {
            bindings = {boss = boss, banner = banner},
        })
        status = "Encounter running."
    end

    world:observe(0, sequence.Event, function(event: sequence.Event)
        LOGGER:info("sequence emitted %s", event.name)
    end)

    spawnHud()
    startEncounter()

    ---------------------------------------------------------------------------
    -- Save and load
    ---------------------------------------------------------------------------

    local function save()
        local snapshot = world:saveSnapshot()
        local ok, err = love.filesystem.write(SAVE_PATH, tostring(snapshot.buffer))
        if not ok then
            status = "Save failed: " .. tostring(err)
            return
        end
        local s = sequence.status(world, encounter)
        status = string.format("Saved at pc %d.", s and s.pc or -1)
        LOGGER:info("%s", status)
    end

    local function loadSave()
        if not love.filesystem.getInfo(SAVE_PATH) then
            status = "No save yet. Press S mid-encounter, then L."
            return
        end
        local payload = love.filesystem.read(SAVE_PATH)
        world:loadSnapshot(payload)
        -- The load replaced the world, including the HUD this demo drew.
        spawnHud()
        local s = sequence.status(world, encounter)
        status = string.format("Loaded at pc %d.", s and s.pc or -1)
        LOGGER:info("%s", status)
    end

    ---------------------------------------------------------------------------
    -- Systems
    ---------------------------------------------------------------------------

    local function killOneAdd()
        for archetype, len in addQuery:iter() do
            local entities = archetype.entities as {integer}
            if len > 0 then
                world:despawn(entities[1])
                addsKilled = addsKilled + 1
                return
            end
        end
    end

    world:addSystem({
        name = "DemoInput",
        phase = tecs.phases.First,
        run = function()
            if input.isKeyPressed("space") then
                killOneAdd()
            elseif input.isKeyPressed("s") then
                save()
            elseif input.isKeyPressed("l") then
                loadSave()
            elseif input.isKeyPressed("r") then
                startEncounter()
            elseif input.isKeyPressed("x") then
                if encounter and sequence.cancel(world, encounter) then
                    status = "Encounter cancelled. R restarts it."
                end
            elseif input.isKeyPressed("p") then
                if encounter then
                    local s = sequence.status(world, encounter)
                    if s and s.state == "paused" then
                        sequence.resume(world, encounter)
                        status = "Resumed."
                    elseif sequence.pause(world, encounter) then
                        status = "Paused. Its tweens and branches paused too."
                    end
                end
            end
        end,
    })

    -- Report what the cursor is doing: the same fields the debugger's
    -- `sequence list` command reads.
    local function cursorLine(): string
        local s = encounter and sequence.status(world, encounter)
        if not s then return "cursor: gone" end
        local blocked = "-"
        if s.waitingFor then
            blocked = "signal " .. s.waitingFor
        elseif s.waitingQuery then
            blocked = string.format("query %s %s", s.waitingQuery, s.waitingCondition)
        elseif s.waitingTween then
            blocked = "tween " .. tostring(s.waitingTween)
        elseif s.joining then
            blocked = string.format("%d branch(es)", s.branches)
        elseif s.wakeAt then
            blocked = "step " .. tostring(s.wakeAt)
        end
        return string.format("pc %d  %s  waiting on %s", s.pc, s.state, blocked)
    end

    world:addSystem({
        name = "DemoHudSync",
        phase = tecs.phases.PostUpdate,
        run = function()
            for archetype, len in hudQuery:iter() do
                local slots = archetype:get(HudSlot) as {HudSlot}
                local texts = archetype:getMut(gfx.Text) as {gfx.Text}
                for i = 1, len do
                    local role = slots[i].role
                    if role == "status" then
                        texts[i]:setText(status)
                    elseif role == "cursor" then
                        texts[i]:setText(cursorLine())
                    elseif role == "adds" then
                        texts[i]:setText(string.format(
                            "adds alive %d   killed %d   step %d",
                            countAdds(), addsKilled, sequence.currentStep(world)))
                    end
                end
            end
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = plugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2},
        layers = {
            [ARENA_LAYER] = {name = "arena", space = "virtual"},
            [HUD_LAYER]   = {name = "hud",   space = "virtual"},
        },
    },
})
