--- Shared fixed-step Transform interpolation for GPU shadow registries.
---
--- Fixed iterations only mark canonical Transform columns. Each registry
--- coalesces those mutations at its PreRender upload boundary:
---
---   zero steps  -> keep the existing sample pair
---   one step    -> rotate once and upload the new sample
---   catch-up    -> upload the final value once and snap

local tecs <const> = require("tecs")
local fixedtracking <const> = require("tecs.internal.fixedtracking")
local archetyperegistry <const> =
    require("tecs2d.gfx.internal.archetyperegistry")
local shadowbuffer <const> =
    require("tecs2d.gfx.internal.gpu.shadowbuffer")
local shadowstate <const> =
    require("tecs2d.gfx.internal.gpu.shadowstate")

local Transform <const> = tecs.builtins.Transform

local record transforminterpolation
    record Controller
        world: tecs.World
        registry: archetyperegistry.Registry
        enabled: boolean
        lastPresentedStep: integer

        --- Flush all shadow columns, rotating Transform only when exactly
        --- one fixed iteration elapsed since the previous presentation.
        flush: function(self)
    end

    new: function(
        world: tecs.World,
        registry: archetyperegistry.Registry,
        disabled: boolean
    ): Controller

    --- Bind current/previous Transform samples and interpolation uniforms.
    bind: function(
        shader: love.graphics.ComputeShader,
        buffer: shadowbuffer.ShadowBuffer,
        world: tecs.World
    )
end

local Controller <const> = transforminterpolation.Controller
local CONTROLLER_MT <const>: metatable<Controller> = {__index = Controller}

function transforminterpolation.new(
    world: tecs.World,
    registry: archetyperegistry.Registry,
    disabled: boolean
): transforminterpolation.Controller
    local self: transforminterpolation.Controller = setmetatable({
        world = world,
        registry = registry,
        enabled = not disabled,
        lastPresentedStep = fixedtracking.currentStep(world),
    }, CONTROLLER_MT)

    if not self.enabled then return self end

    fixedtracking.track(world, Transform)
    fixedtracking.beforeStep(world, function()
        if fixedtracking.currentStep(world) ~=
                self.lastPresentedStep + 1 then
            return
        end
        for _, stateAny in registry:archetypes() do
            local state = stateAny as shadowstate.ArchetypeState
            if not state.destroyed then
                -- Preserve a variable-rate snap baseline once before
                -- fixed catch-up starts.
                state.shadows:flushCurrent(Transform)
            end
        end
    end)

    return self
end

function Controller:flush()
    if self.enabled then
        local currentStep = fixedtracking.currentStep(self.world)
        local elapsedSteps = currentStep - self.lastPresentedStep
        if elapsedSteps == 1 then
            for arch, stateAny in self.registry:archetypes() do
                if fixedtracking.wroteThisStep(
                    self.world,
                    arch,
                    Transform
                ) then
                    local state = stateAny as shadowstate.ArchetypeState
                    if not state.destroyed then
                        state.shadows:flushFixed(
                            Transform,
                            currentStep
                        )
                    end
                end
            end
        end
        self.lastPresentedStep = currentStep
    end

    self.registry:flushAll()
end

function transforminterpolation.bind(
    shader: love.graphics.ComputeShader,
    buffer: shadowbuffer.ShadowBuffer,
    world: tecs.World
)
    shader:send("TransformInput", buffer.gpuBuffer)
    if not shader:hasUniform("PreviousTransformInput") then return end

    shader:send(
        "PreviousTransformInput",
        buffer.previousGpuBuffer or buffer.gpuBuffer
    )
    local active = buffer.previousGpuBuffer ~= nil
        and buffer.interpolationStep == fixedtracking.currentStep(world)
    shader:send("TransformInterpolationActive", active and 1 or 0)

    local _, _, alpha = world:getFixedTiming()
    shader:send("TransformInterpolationAlpha", alpha)
end

return transforminterpolation
