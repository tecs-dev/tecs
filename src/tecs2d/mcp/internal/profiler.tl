--- Profiler MCP tools: a thin pass-through over tecs.utils.profile.sample
--- with an auto-stop system for timed recordings.

local tecs <const> = require("tecs")
local profile <const> = require("tecs.utils.profile")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")

local lt <const> = love.timer

local record profiler
    install: function(ctx: state.Context)
end

local ctx: state.Context = nil

local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld

local handlers: {string: rpc.Handler} = {}

local AUTOSTOP_SYSTEM_NAME <const> = "mcp.ProfilerAutoStop"

local sampleSession: profile.SampleSession = nil
-- When auto-stop fires, the captured collapsed-stack text is stashed here so
-- a later profiler_stop call can still retrieve the recording.
local pendingSampleResult: string = nil

local function removeAutostopSystem()
    local world = ctx and ctx.world
    if world then
        pcall(function() world:removeSystem(AUTOSTOP_SYSTEM_NAME) end)
    end
end

local function emitResult(id: number, result: string, isPath: boolean)
    if isPath then
        sendToolOK(id, {path = result})
    else
        sendToolOK(id, {format = "collapsed-stack", payload = result, bytes = #result})
    end
end

handlers["profiler_start"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    if sampleSession then
        sendToolError(id, "profiler_already_running", "Profiler is already running; call profiler_stop first")
        return
    end

    local seconds = args.seconds as number
    if seconds and seconds < 0.1 then seconds = 0.1 end
    if seconds and seconds > 60 then seconds = 60 end

    removeAutostopSystem()
    pendingSampleResult = nil
    sampleSession = profile.sample({
        intervalMs = args.intervalMs as integer,
        zone = args.zone as string,
    })

    if seconds then
        local deadline = lt.getTime() + seconds
        world:addSystem({
            name = AUTOSTOP_SYSTEM_NAME,
            phase = tecs.phases.First,
            runIf = function(): boolean
                return lt.getTime() >= deadline
            end,
            run = function(_dt: number, w: tecs.World)
                if sampleSession then
                    pendingSampleResult = sampleSession:stop()
                    sampleSession = nil
                end
                w:removeSystem(AUTOSTOP_SYSTEM_NAME)
            end,
        })
    end

    sendToolOK(id, {
        running = true,
        seconds = seconds,
        intervalMs = args.intervalMs as integer,
        zone = args.zone as string
    })
end

handlers["profiler_stop"] = function(args: {string:any}, id: number)
    local saveTo = args.saveTo as string
    if pendingSampleResult then
        local text = pendingSampleResult
        pendingSampleResult = nil
        if saveTo then
            local f, openErr = io.open(saveTo, "w")
            if not f then
                sendToolError(id, "write_failed", "Failed to write profiler output", {
                    path = saveTo,
                    error = openErr or "unknown"
                })
                return
            end
            f:write(text)
            f:close()
            emitResult(id, saveTo, true)
        else
            emitResult(id, text, false)
        end
        return
    end
    if not sampleSession then
        sendToolError(id, "profiler_not_running", "Profiler is not running")
        return
    end
    local result = sampleSession:stop(saveTo)
    sampleSession = nil
    removeAutostopSystem()
    emitResult(id, result, saveTo ~= nil)
end

function profiler.install(c: state.Context)
    ctx = c
    for name, fn in pairs(handlers) do
        rpc.handlers[name] = fn
    end
end

return profiler
