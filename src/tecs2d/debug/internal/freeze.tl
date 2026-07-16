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
local frameclock <const> = require("tecs2d.internal.frameclock")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("tecs2d.debug.freeze")

local record freeze
    record Controller
        world: tecs.World
        holders: {string: boolean}
        holderCount: integer
        savedTimeScale: number
        stepsRemaining: integer
        stepping: boolean

        --- dt each stepped frame carries; nil means frameclock.nominal
        --- (1 / config.fps). Stepping is deterministic: `step n` advances
        --- exactly n * stepDt gameplay seconds on every machine.
        stepDt: number

        --- The provider this controller installed on frameclock (nil when
        --- not stepping, or when a replay owned the provider first).
        ownProvider: function(number): number

        --- One-shot callbacks fired when the pending step's last frame has
        --- run (or the freeze is released mid-step, so no waiter strands).
        stepWaiters: {function()}

        --- Optional per-frame hook, evaluated after each stepped frame's
        --- gameplay has run; returning true ends the step early. Cleared
        --- when the step completes or the freeze is released.
        perFrame: function(): boolean

        --- Frames actually run by the current/most recent step (a per-frame
        --- hook can stop before the requested count).
        stepFramesRun: integer

        --- True when the most recent step was ended early by its per-frame
        --- hook.
        stoppedEarly: boolean

        --- Register a one-shot step-completion callback. Fires immediately
        --- when no step is pending.
        onStepComplete: function(self: Controller, fn: function())

        flushStepWaiters: function(self: Controller)

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

        installStepClock: function(self: Controller)
        removeStepClock: function(self: Controller)
    end

    KEY: tecs.Key<Controller>

    --- Get or create the world's freeze controller (installs its tick system
    --- on creation). Safe to call from any plugin, in any order.
    ensure: function(w: tecs.World): Controller
end

freeze.KEY = tecs.newKey("tecs2d.debug.freeze")

-- Every gameplay phase. The debugger overlay draws in RenderLast, MCP runs in
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
    local rp = w.resources[pipelinekey.PIPELINE]
    if not rp then return end
    rp:setTimeScale(scale)
end

local function getRenderTimeScale(w: tecs.World): number
    local rp = w.resources[pipelinekey.PIPELINE]
    if not rp then return 1.0 end
    return rp:getTimeScale()
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
        self.perFrame = nil
        self:removeStepClock()
        -- A release mid-step resolves waiters rather than stranding their
        -- deferred responses; the game is running, the step is moot.
        self:flushStepWaiters()
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
    self.stepFramesRun = 0
    self.stoppedEarly = false
    return true, nil
end

-- Fire and clear every registered step waiter. Each callback runs isolated
-- so one bad waiter cannot strand the others (or kill the tick system).
function freeze.Controller:flushStepWaiters()
    local waiters = self.stepWaiters
    if not waiters or #waiters == 0 then return end
    self.stepWaiters = {}
    for i = 1, #waiters do
        local ok, err = pcall(waiters[i]) as (boolean, any)
        if not ok then
            LOGGER:error("step waiter failed: %s", tostring(err))
        end
    end
end

function freeze.Controller:onStepComplete(fn: function())
    if self.stepsRemaining <= 0 and not self.stepping then
        pcall(fn)
        return
    end
    self.stepWaiters = self.stepWaiters or {}
    self.stepWaiters[#self.stepWaiters + 1] = fn
end

-- Install a deterministic-dt provider for the duration of a step, unless a
-- replay already owns the frameclock (its recorded dts must win).
function freeze.Controller:installStepClock()
    if frameclock.provider ~= nil then return end
    local ctl = self
    self.ownProvider = function(_realDt: number): number
        return ctl.stepDt or frameclock.nominal
    end
    frameclock.provider = self.ownProvider
end

function freeze.Controller:removeStepClock()
    if self.ownProvider ~= nil and frameclock.provider == self.ownProvider then
        frameclock.provider = nil
    end
    self.ownProvider = nil
end

-- Step: run the frozen gameplay phases for N frames, then re-freeze. Enabling
-- here takes effect on the next update (RenderFirst is after the gameplay
-- phases), so each tick past the enable counts exactly one gameplay frame.
-- Stepped frames carry a deterministic dt (stepDt or frameclock.nominal)
-- instead of the display-rate-dependent measured dt, so `step n` advances the
-- same amount of gameplay time on a 60Hz and a 120Hz machine.
function freeze.Controller:tick()
    if self.holderCount == 0 or self.stepsRemaining <= 0 then return end
    if not self.stepping then
        self:installStepClock()
        enableGameplay(self.world)
        setRenderTimeScale(self.world, self.savedTimeScale)
        self.stepping = true
        return
    end
    self.stepsRemaining = self.stepsRemaining - 1
    self.stepFramesRun = (self.stepFramesRun or 0) + 1

    -- Per-frame hook: this frame's gameplay has run (RenderFirst is after the
    -- gameplay phases), so the hook observes its result; returning true stops
    -- the step here. It runs on the natural last frame too (side effects stay
    -- per-frame-consistent), where its verdict is moot.
    if self.perFrame then
        local okH, stop = pcall(self.perFrame) as (boolean, any)
        if okH and stop and self.stepsRemaining > 0 then
            self.stepsRemaining = 0
            self.stoppedEarly = true
        elseif not okH then
            -- A broken hook must not run the world unattended for the rest
            -- of the step; stop and let the waiter surface the error.
            self.stepsRemaining = 0
            self.stoppedEarly = true
        end
    end

    if self.stepsRemaining <= 0 then
        disableGameplay(self.world)
        setRenderTimeScale(self.world, 0.0)
        self.stepping = false
        self.perFrame = nil
        self:removeStepClock()
        -- The last stepped frame's gameplay phases have run (RenderFirst is
        -- after them), so waiters observe post-step state.
        self:flushStepWaiters()
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
