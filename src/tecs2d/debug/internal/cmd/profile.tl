--- LuaJIT profiler debugger command.

local profile <const> = require("tecs.utils.profile")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local artifacts <const> = require("tecs2d.debug.internal.artifacts")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format
local getTime <const> = love.timer.getTime

local record profilecmd
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

-- seconds 0 samples until you reopen the debugger.
local profileSchema <const>: cmdargs.Schema = {
    args = {
        seconds = {default = 0, help = "sample duration; 0 samples until reopen"},
        intervalMs = {kind = "number",
            help = "sampler interval in ms (sampler default if omitted; raise for long sessions)"},
        zone = {help = "restrict output to samples whose zone path starts with this prefix"},
    },
    positional = {"seconds"},
}
cmdargs.validate(profileSchema)

local captureRefSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "capture name or list index"} },
    positional = {"ref"},
}

function profilecmd.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world
    local ctx <const> = d.ctx
    local reg <const> = d.reg
    local env <const> = d.env
    local summarizeProfile <const> = d.summarizeProfile
    local systemZoneIds <const> = d.systemZoneIds

    return {
        {
            name = "profile",
            section = "Capture",
            shortHelp = "sample the running game with the LuaJIT profiler",
            mcpHelp = "Start the LuaJIT sampling profiler for seconds (0.1-60; capped) and write a collapsed-stack capture when it finishes. The capture lands in the process working directory and its summary publishes to cmd_context; fetch details with cmd_profile_info and cmd_profile_path. Filtering (zone=) and intervalMs are fixed at start.",
            schema = profileSchema,
            examples = {"profile", "profile 5", "profile 5 intervalMs=5",
                "profile zone=afterFixed/Render", "profile list"},
            subcommands = {
                artifacts.list("profiles",
                    function(): {any} return ctx.profiles as {any} end,
                    function(e: any): string
                        local p = e as debugcontext.ProfileEntry
                        return format("  %.1f KB\t%s\t%s",
                            p.size / 1024, os.date("%Y-%m-%d %H:%M:%S", p.time) as string, p.path)
                    end),
                -- Profiles land in the process working directory, not the save
                -- dir, so clearing goes through os.remove.
                artifacts.clear("profiles",
                    function(): {any} return ctx.profiles as {any} end,
                    function(path: string) os.remove(path) end,
                    function() ctx.profiles = {} end),
                artifacts.info("profile", "capture", "re-show a capture's summary (latest if omitted)",
                    captureRefSchema,
                    function(): {any} return ctx.profiles as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local f = io.open(e.path as string, "r")
                        if not f then
                            return {ok = false, code = "read_failed",
                                message = "profile info: cannot read " .. tostring(e.path)}
                        end
                        local text = f:read("*a")
                        f:close()
                        local popup, top = summarizeProfile(text, e.path as string, systemZoneIds(w))
                        return {ok = true, popup = popup,
                            data = {path = e.path, size = e.size, summary = top}}
                    end),
                artifacts.path("profile", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.profiles as {any}, ref)
                        return e and e.path as string
                    end,
                    -- Captures live in the process working directory.
                    function(rel: string): string
                        return love.filesystem.getWorkingDirectory() .. "/" .. rel
                    end),
                {
                    name = "open",
                    shortHelp = "open speedscope and copy the capture's path to the clipboard",
                    schema = captureRefSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local e = artifacts.find(ctx.profiles as {any}, v.ref as string)
                        if not e then
                            return {ok = false, code = "no_match",
                                message = "profile open: no capture for '" .. tostring(v.ref) .. "'. Use `profile list`."}
                        end
                        -- Captures live in the process working directory.
                        local absPath = love.filesystem.getWorkingDirectory() .. "/" .. (e.path as string)
                        love.system.setClipboardText(absPath)
                        local url = "https://www.speedscope.app/"
                        pcall(function() love.system.openURL(url) end)
                        return {ok = true,
                            message = "opened speedscope; capture path in clipboard: " .. absPath,
                            data = {path = absPath, url = url}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                if reg.profiler.session then
                    return {ok = false, code = "already_running", message = "profile: already running"}
                end
                local secs = v.seconds as number
                local opts: profile.SampleOptions = {}
                if v.intervalMs ~= nil then
                    opts.intervalMs = math.floor(v.intervalMs as number) as integer
                end
                if v.zone ~= nil then
                    opts.zone = v.zone as string
                end
                local ok, sess = pcall(profile.sample, opts)
                if not ok or not sess then
                    return {ok = false, code = "start_failed",
                        message = "profile: could not start (already sampling?)"}
                end
                reg.profiler.session = sess as profile.SampleSession
                reg.signals.action = "exit"
                if secs > 0 then
                    if secs < 0.1 then secs = 0.1 end
                    if secs > 60 then secs = 60 end
                    reg.profiler.deadline = getTime() + secs
                    return {ok = true, message = "profiling " .. tostring(secs) .. "s"}
                end
                reg.profiler.deadline = 0.0
                return {ok = true, message = "profiling until reopen (" ..
                    env.keys.leader .. "+" .. env.keys.debugToggle .. ")"}
            end,
        }
    }
end

return profilecmd
