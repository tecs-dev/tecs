--- Shared freeze/step controller: the one owner of "gameplay is stopped".
--- Both the in-game debugger (open panel) and the MCP pause tool freeze
--- through this resource, so the two surfaces cannot fight over phase state
--- or clobber each other's saved time scale. Freezing disables every
--- gameplay phase and zeroes the render time scale; rendering, input, the
--- overlay, and the MCP server keep running.
---
--- Holders are named ("debugger", "mcp"): the world freezes when the first
--- holder acquires and thaws when the last releases. Stepping ticks the
--- gameplay phases for exactly N frames while frozen, then re-freezes.

local tecs <const> = require("tecs")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")

local record freeze
    record Controller
        world: tecs.World
        holders: {string: boolean}
        holderCount: integer
        savedTimeScale: number
        stepsRemaining: integer
        stepping: boolean

        --- Freeze on behalf of `who`. Returns false if already held by them.
        acquire: function(self: Controller, who: string): boolean

        --- Release `who`'s hold; thaws when no holder remains. Returns false
        --- if they held nothing.
        release: function(self: Controller, who: string): boolean

        heldBy: function(self: Controller, who: string): boolean
        isFrozen: function(self: Controller): boolean

        --- Queue N gameplay frames while frozen. Returns false + reason when
        --- not frozen.
        step: function(self: Controller, frames: integer): boolean, string

        --- Per-frame step state machine; driven by the debug.FreezeStep system.
        tick: function(self: Controller)
    end

    KEY: tecs.Key<Controller>

    --- Get or create the world's freeze controller (installs its tick system
    --- on creation). Safe to call from any plugin, in any order.
    ensure: function(w: tecs.World): Controller
end

freeze.KEY = tecs.newKey()

-- Every gameplay phase. The debugger overlay draws in PostRender, MCP runs in
-- RenderFirst, and the event poller runs outside the phase system, so
-- disabling these stops the game while input, tools, and drawing keep working.
local GAMEPLAY_PHASES <const>: {tecs.Phase} = {
    tecs.phases.First,
    tecs.phases.PreUpdate,
    tecs.phases.FixedUpdateGroup,
    tecs.phases.Update,
    tecs.phases.PostUpdate,
    tecs.phases.Last,
}

local function setRenderTimeScale(w: tecs.World, scale: number)
    local rp = w.resources[pipelinekey.PIPELINE] as {string: any}
    if not rp then return end
    if rp.setTimeScale then
        (rp.setTimeScale as function(any, number))(rp, scale)
    else
        rp.timeScale = scale
    end
end

local function getRenderTimeScale(w: tecs.World): number
    local rp = w.resources[pipelinekey.PIPELINE] as {string: any}
    if not rp then return 1.0 end
    return (rp.timeScale as number) or 1.0
end

local function disableGameplay(w: tecs.World)
    for i = 1, #GAMEPLAY_PHASES do
        w:disablePhase(GAMEPLAY_PHASES[i])
    end
end

local function enableGameplay(w: tecs.World)
    for i = 1, #GAMEPLAY_PHASES do
        w:enablePhase(GAMEPLAY_PHASES[i])
    end
end

function freeze.Controller:acquire(who: string): boolean
    if self.holders[who] then return false end
    self.holders[who] = true
    self.holderCount = self.holderCount + 1
    if self.holderCount == 1 then
        self.savedTimeScale = getRenderTimeScale(self.world)
        setRenderTimeScale(self.world, 0.0)
        disableGameplay(self.world)
        self.stepsRemaining = 0
        self.stepping = false
    end
    return true
end

function freeze.Controller:release(who: string): boolean
    if not self.holders[who] then return false end
    self.holders[who] = nil
    self.holderCount = self.holderCount - 1
    if self.holderCount == 0 then
        enableGameplay(self.world)
        setRenderTimeScale(self.world, self.savedTimeScale)
        self.stepsRemaining = 0
        self.stepping = false
    end
    return true
end

function freeze.Controller:heldBy(who: string): boolean
    return self.holders[who] == true
end

function freeze.Controller:isFrozen(): boolean
    return self.holderCount > 0
end

function freeze.Controller:step(frames: integer): boolean, string
    if self.holderCount == 0 then
        return false, "not frozen"
    end
    if frames < 1 then frames = 1 end
    self.stepsRemaining = frames
    return true, nil
end

-- Step: run the frozen gameplay phases for N frames, then re-freeze. Enabling
-- here takes effect on the next update (RenderFirst is after the gameplay
-- phases), so each tick past the enable counts exactly one gameplay frame.
function freeze.Controller:tick()
    if self.holderCount == 0 or self.stepsRemaining <= 0 then return end
    if not self.stepping then
        enableGameplay(self.world)
        setRenderTimeScale(self.world, self.savedTimeScale)
        self.stepping = true
        return
    end
    self.stepsRemaining = self.stepsRemaining - 1
    if self.stepsRemaining <= 0 then
        disableGameplay(self.world)
        setRenderTimeScale(self.world, 0.0)
        self.stepping = false
    end
end

function freeze.ensure(w: tecs.World): freeze.Controller
    local existing = w.resources[freeze.KEY]
    if existing then return existing end
    local self: freeze.Controller = {
        world = w,
        holders = {},
        holderCount = 0,
        savedTimeScale = 1.0,
        stepsRemaining = 0,
        stepping = false,
    } as freeze.Controller
    setmetatable(self as {string: any}, {__index = freeze.Controller})
    w.resources[freeze.KEY] = self
    w:addSystem({
        name = "debug.FreezeStep",
        phase = tecs.phases.RenderFirst,
        run = function()
            self:tick()
        end,
    })
    return self
end

return freeze
