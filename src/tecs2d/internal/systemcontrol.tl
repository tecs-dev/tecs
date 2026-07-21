--- Runtime enable/disable of systems by name, shared by the MCP toggle_system
--- tool and the debugger's `systems` command. Disabling wraps the system's
--- runIf with a gate; enabling restores the original, so repeated
--- disable/enable cycles never nest wrappers.

local tecs <const> = require("tecs")

local record systemcontrol
    record Info
        name: string
        phase: string
        enabled: boolean
        -- 1-based order within its phase.
        position: integer
        -- Whether the system declares its own runIf (beyond the disable gate).
        hasRunIf: boolean
    end

    --- Every system in pipeline order with its phase and enabled state.
    list: function(w: tecs.World): {Info}

    --- One system's info, or nil when the name is unknown.
    info: function(w: tecs.World, name: string): Info

    --- Enable or disable a system by name. Returns false + reason when the
    --- system does not exist.
    setEnabled: function(w: tecs.World, name: string, enabled: boolean): boolean, string

    isEnabled: function(w: tecs.World, name: string): boolean
end

local record State
    disabledSystems: {string: boolean}
end

local STATE <const>: tecs.Key<State> = tecs.newKey("tecs2d.systemcontrol")

local function stateFor(w: tecs.World): State
    local state = w.resources[STATE]
    if state then return state end
    state = {disabledSystems = {}}
    w.resources[STATE] = state
    return state
end

local function pipelineOf(w: tecs.World): {string: any}
    return (w as {string: any}).pipeline as {string: any}
end

local function findConfig(w: tecs.World, name: string): tecs.SystemConfig, integer
    local pipeline = pipelineOf(w)
    local registry = pipeline.systemNameRegistry as {string: integer}
    local pos = registry[name]
    if not pos then return nil, 0 end
    local systems = pipeline.systems as {{tecs.SystemConfig}}
    local phaseSystems = systems[pos]
    for i = 1, #phaseSystems do
        if phaseSystems[i].name == name then
            return phaseSystems[i], i
        end
    end
    return nil, 0
end

local function infoFor(config: tecs.SystemConfig, position: integer,
        disabledSystems: {string: boolean}): systemcontrol.Info
    local name = config.name or "(anonymous)"
    local configAny = config as {string: any}
    local hasOwnRunIf: boolean
    if disabledSystems[name] then
        hasOwnRunIf = configAny._originalRunIf ~= nil
    else
        hasOwnRunIf = config.runIf ~= nil
    end
    return {
        name = name,
        phase = config.phase and config.phase.name or "(unknown)",
        enabled = not disabledSystems[name],
        position = position,
        hasRunIf = hasOwnRunIf,
    }
end

function systemcontrol.list(w: tecs.World): {systemcontrol.Info}
    local disabledSystems = stateFor(w).disabledSystems
    local pipeline = pipelineOf(w)
    local systems = pipeline.systems as {{tecs.SystemConfig}}
    local out: {systemcontrol.Info} = {}
    for i = 1, #systems do
        local phaseSystems = systems[i]
        for j = 1, #phaseSystems do
            out[#out + 1] = infoFor(phaseSystems[j], j, disabledSystems)
        end
    end
    return out
end

function systemcontrol.info(w: tecs.World, name: string): systemcontrol.Info
    local config, position = findConfig(w, name)
    if not config then return nil end
    return infoFor(config, position, stateFor(w).disabledSystems)
end

function systemcontrol.isEnabled(w: tecs.World, name: string): boolean
    return not stateFor(w).disabledSystems[name]
end

function systemcontrol.setEnabled(w: tecs.World, name: string, enabled: boolean): boolean, string
    local disabledSystems = stateFor(w).disabledSystems
    local config = findConfig(w, name)
    if not config then
        return false, "system not found: " .. name
    end
    -- The pipeline compiles runIf into flat groups; mark it dirty so the
    -- mutated config is recompiled before the next update. Without this a
    -- toggle only takes effect when something else rebuilds the pipeline.
    pipelineOf(w).dirty = true
    if enabled then
        -- Restore the original runIf if we wrapped it. Always restore, even
        -- when the original was nil: leaving the wrapper installed makes the
        -- next disable capture the wrapper as the "original", nesting one
        -- closure per disable/enable cycle forever.
        if disabledSystems[name] then
            disabledSystems[name] = nil
            local configAny = config as {string: any}
            config.runIf = configAny._originalRunIf as function(number, tecs.World, string): boolean
            configAny._originalRunIf = nil
        end
        return true, nil
    end
    if not disabledSystems[name] then
        disabledSystems[name] = true
        local originalRunIf = config.runIf;
        (config as {string: any})._originalRunIf = originalRunIf
        config.runIf = function(_dt: number, _world: tecs.World, sysName: string): boolean
            if disabledSystems[sysName] then
                return false
            end
            if not originalRunIf then
                return true
            end
            return originalRunIf(_dt, _world, sysName)
        end
    end
    return true, nil
end

return systemcontrol
