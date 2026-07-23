--- Capture-section command for transition breakpoints.

local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local breakpoints <const> = require("tecs2d.debug.internal.breakpoints")

local record breakpointcmd
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local selectorSchema <const>: cmdargs.Schema = {
    args = {
        selector = {
            rest = true,
            required = true,
            completion = "breakpointselectors",
            help = "transition selector; terms are ANDed and || separates branches",
        },
    },
    positional = {"selector"},
}
cmdargs.validate(selectorSchema)

local idSchema <const>: cmdargs.Schema = {
    args = {
        id = {
            kind = "number",
            required = true,
            min = 1,
            completion = "breakpointids",
            help = "breakpoint number from `breakpoint list`",
        },
    },
    positional = {"id"},
}
cmdargs.validate(idSchema)

local function entryData(entry: breakpoints.Breakpoint): {string: any}
    return {
        id = entry.id,
        selector = entry.source,
        enabled = entry.enabled,
        hits = entry.hits,
    }
end

function breakpointcmd.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local manager = d.world.resources[breakpoints.KEY]

    local function requireEntry(id: integer): breakpoints.Breakpoint,
        cmdtypes.Result
        local entry = manager.byId[id]
        if entry then return entry, nil end
        return nil, {
            ok = false,
            code = "breakpoint_not_found",
            message = "breakpoint: no breakpoint #" .. tostring(id),
        }
    end

    return {
        {
            name = "breakpoint",
            section = "Capture",
            shortHelp = "stop on entity or state transitions",
            examples = {
                "breakpoint add has=Transform lacks=Disabled",
                "breakpoint add removed=Health || life=despawn",
                'breakpoint add pushed="Pause" state=Pause',
                "breakpoint list",
                "breakpoint disable 1",
                "breakpoint continue",
            },
            subcommands = {
                {
                    name = "add",
                    shortHelp = "compile and enable a transition selector",
                    schema = selectorSchema,
                    run = function(v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local entry, err = manager:add(v.selector as string)
                        if not entry then
                            return {
                                ok = false,
                                code = "invalid_selector",
                                message = "breakpoint: " .. err,
                            }
                        end
                        return {
                            ok = true,
                            message = "breakpoint #" .. tostring(entry.id)
                                .. " armed",
                            data = entryData(entry),
                        }
                    end,
                },
                {
                    name = "list",
                    shortHelp = "list breakpoints, hit counts, and enabled state",
                    run = function(_v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local entries = manager:list()
                        local popup: {string} = {}
                        local data: {{string: any}} = {}
                        for i = 1, #entries do
                            local entry = entries[i]
                            local state = entry.enabled and "armed" or "disabled"
                            popup[#popup + 1] = string.format(
                                "#%d  %-8s  %d hit%s  %s",
                                entry.id, state, entry.hits,
                                entry.hits == 1 and "" or "s", entry.source)
                            data[#data + 1] = entryData(entry)
                        end
                        if #popup == 0 then popup[1] = "No breakpoints." end
                        return {
                            ok = true,
                            popupTitle = "Breakpoints",
                            popup = popup,
                            data = {count = #entries, breakpoints = data},
                        }
                    end,
                },
                {
                    name = "enable",
                    shortHelp = "enable a breakpoint",
                    schema = idSchema,
                    run = function(v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local id = math.floor(v.id as number) as integer
                        local entry, failure = requireEntry(id)
                        if failure then return failure end
                        manager:setEnabled(id, true)
                        return {
                            ok = true,
                            message = "breakpoint #" .. tostring(id) .. " armed",
                            data = entryData(entry),
                        }
                    end,
                },
                {
                    name = "disable",
                    shortHelp = "disable a breakpoint without removing it",
                    schema = idSchema,
                    run = function(v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local id = math.floor(v.id as number) as integer
                        local entry, failure = requireEntry(id)
                        if failure then return failure end
                        manager:setEnabled(id, false)
                        return {
                            ok = true,
                            message = "breakpoint #" .. tostring(id)
                                .. " disabled",
                            data = entryData(entry),
                        }
                    end,
                },
                {
                    name = "remove",
                    shortHelp = "delete a breakpoint",
                    schema = idSchema,
                    run = function(v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local id = math.floor(v.id as number) as integer
                        local entry, failure = requireEntry(id)
                        if failure then return failure end
                        local data = entryData(entry)
                        manager:remove(id)
                        return {
                            ok = true,
                            message = "removed breakpoint #" .. tostring(id),
                            data = data,
                        }
                    end,
                },
                {
                    name = "clear",
                    shortHelp = "delete every breakpoint",
                    run = function(_v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        local count = manager:clear()
                        return {
                            ok = true,
                            message = "removed " .. tostring(count)
                                .. " breakpoint" .. (count == 1 and "" or "s"),
                            data = {count = count},
                        }
                    end,
                },
                {
                    name = "continue",
                    shortHelp = "leave a breakpoint stop and resume gameplay",
                    run = function(_v: {string: any},
                        _parts: {string}): cmdtypes.Result
                        if d.ctx.open then
                            d.reg.signals.action = "exit"
                        else
                            d.env.suspension:resume("debugger")
                            d.ctx.frozen = false
                        end
                        return {
                            ok = true,
                            message = "continued",
                            data = {continued = true},
                        }
                    end,
                },
            },
        },
    }
end

return breakpointcmd
