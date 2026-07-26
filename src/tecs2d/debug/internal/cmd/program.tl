--- Running sequencer programs from the debugger.
---
--- One tool takes a whole scripted scenario -- input, waits, spawns, tween
--- moves, signals -- as data, plays it, and hands back a handle to watch. It
--- replaces queueing input through one tool and doing everything else through
--- run_lua, neither of which survives a save; a program does.
---
--- The world-editing steps are registered actions rather than instructions,
--- so the sequencer stays a control-flow machine and a game can register its
--- own steps exactly the same way.

local tecs <const> = require("tecs")
local sequence <const> = require("tecs2d.sequence")
local inputtape <const> = require("tecs2d.debug.internal.inputtape")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format

local record programcmds
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

-- Programs a tool authors are versioned under one name, like the input
-- tape's: a version is dropped when its playback finishes.
local PROGRAM_NAME <const> = "tecs2d.debug.program"

local playSchema <const>: cmdargs.Schema = {
    args = {
        steps = {required = true, kind = "rows",
            help = "the program: a list of {op = ...} steps"},
        clock = {default = "fixed", enum = {"fixed", "frame"},
            help = "fixed counts fixed steps; frame counts gameplay frames and runs while stepping"},
        bindings = {kind = "table",
            help = "entity ids the program acts on, by name"},
    },
    positional = {"steps"},
}
cmdargs.validate(playSchema)

local handleSchema <const>: cmdargs.Schema = {
    args = { handle = {required = true, kind = "number",
        help = "playback handle from `program play`"} },
    positional = {"handle"},
}
cmdargs.validate(handleSchema)

-- Steps that edit the world. Registered per world so a program can act
-- without the game having registered anything itself.
local function registerEditActions(w: tecs.World, componentFor: function(string): (tecs.Component, string))
    local function componentsFrom(spec: {string: any}): {tecs.Component}, string
        local out: {tecs.Component} = {}
        for name, fields in pairs(spec or {}) do
            local comp, err = componentFor(name as string)
            if not comp then return nil, err end
            local ctor = comp as any as function(...: any): tecs.Component
            local instance = ctor()
            local target = instance as {string: any}
            for k, v in pairs(fields as {string: any}) do target[k] = v end
            out[#out + 1] = instance
        end
        return out, nil
    end

    sequence.registerAction(w, "tecs2d.spawn",
        function(world: tecs.World, ctx: sequence.ActionContext)
            local spec <const> = ctx.args[1] as {string: any}
            local comps, err = componentsFrom(spec)
            if not comps then error(err) end
            local id <const> = world:spawn(table.unpack(comps))
            -- Naming it lets the steps that follow act on what this made.
            local name <const> = ctx.args[2] as string
            if name then ctx:bind(name, id) end
        end)

    sequence.registerAction(w, "tecs2d.set",
        function(world: tecs.World, ctx: sequence.ActionContext)
            local entity <const> = ctx:entity(ctx.args[1] as string)
            if not entity then return end
            local comps, err = componentsFrom(ctx.args[2] as {string: any})
            if not comps then error(err) end
            for i = 1, #comps do world:set(entity, comps[i]) end
        end)

    sequence.registerAction(w, "tecs2d.despawn",
        function(world: tecs.World, ctx: sequence.ActionContext)
            local entity <const> = ctx:entity(ctx.args[1] as string)
            if entity then world:despawn(entity) end
        end)
end

-- `input` is the tape's dispatch action wearing a friendlier name. The
-- translation lives here rather than in the codec, which has no business
-- knowing a debug module's action names.
local rewriteInput: function(rows: {any}): {any}
rewriteInput = function(rows: {any}): {any}
    if not rows is table then return rows end
    local out: {any} = {}
    for i = 1, #(rows as {any}) do
        local row = (rows as {any})[i]
        if row is table then
            local entry = row as {string: any}
            if entry.op == "input" then
                out[i] = {
                    op = "call",
                    action = inputtape.DISPATCH_ACTION,
                    args = {entry.event, entry.args or {}},
                }
            else
                local copy: {string: any} = {}
                for k, v in pairs(entry) do copy[k] = v end
                if copy.nodes ~= nil then copy.nodes = rewriteInput(copy.nodes as {any}) end
                if copy.blocks ~= nil then
                    local blocks: {any} = {}
                    for j = 1, #(copy.blocks as {any}) do
                        blocks[j] = rewriteInput((copy.blocks as {any})[j] as {any})
                    end
                    copy.blocks = blocks
                end
                out[i] = copy
            end
        else
            out[i] = row
        end
    end
    return out
end

local function statusData(w: tecs.World, handle: integer): {string: any}
    local s <const> = sequence.status(w, handle)
    if not s then return nil end
    local ahead <const> = sequence.upcoming(w, handle)
    local ahead2: {{string: any}} = {}
    for i = 1, #ahead do
        ahead2[i] = {["in"] = ahead[i].ticks, kind = ahead[i].kind, name = ahead[i].name}
    end
    return {
        handle = handle,
        state = s.state,
        pc = s.pc,
        program = s.program,
        version = s.version,
        wakeAt = s.wakeAt,
        waitingFor = s.waitingFor,
        waitingQuery = s.waitingQuery,
        waitingTween = s.waitingTween,
        branches = s.branches,
        fault = s.fault,
        faultMessage = s.faultMessage,
        upcoming = ahead2,
    }
end

function programcmds.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world
    registerEditActions(w, d.componentFor)
    inputtape.ensure(w)

    return {
        {
            name = "program",
            section = "Session",
            shortHelp = "play a scripted program: input, waits, spawns, tweens",
            mcpHelp = "Play a sequencer program given as data, and get a handle back. A program is a list of steps -- "
                .. table.concat(sequence.dataOps(), ", ")
                .. ", plus `input` for love events -- which run in order on a clock, so a scenario is scheduled rather "
                .. "than fired all at once. Unlike run_lua it survives a snapshot: save mid-program and the load "
                .. "resumes at the same step. Use `program status` to watch one and `program cancel` to stop it.",
            examples = {
                'program play [{"op":"input","event":"keypressed","args":["space"]},{"op":"wait","seconds":0.5}] clock=frame',
                'program play [{"op":"call","action":"game.spawnWave"},{"op":"waitQuery","query":"game.adds","condition":"empty"}]',
                "program status 1048577",
                "program cancel 1048577",
            },
            subcommands = {
                {
                    name = "play",
                    shortHelp = "compile a program from steps and play it",
                    schema = playSchema,
                    annotations = {readOnlyHint = false, destructiveHint = false,
                        idempotentHint = false, openWorldHint = false},
                    outputSchema = {
                        type = "object",
                        properties = {
                            handle = {type = "integer", description = "playback handle"},
                            steps = {type = "integer", description = "steps compiled"},
                            clock = {type = "string"},
                        },
                        required = {"handle", "steps", "clock"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local rows = v.steps
                        if rows is string then
                            return {ok = false, code = "invalid_program",
                                message = "program play: steps must be a list of objects"}
                        end
                        local clock <const> = v.clock as string
                        local prog, err = sequence.defineData(PROGRAM_NAME,
                            rewriteInput(rows as {any}),
                            {clock = clock as sequence.ClockId})
                        if not prog then
                            return {ok = false, code = "invalid_program",
                                message = "program play: " .. err}
                        end
                        local handle <const> = sequence.play(w, prog, {
                            bindings = v.bindings as {string: integer},
                        })
                        return {
                            ok = true,
                            message = format("playing %d step(s) on the %s clock as %d",
                                #(rows as {any}), clock, handle),
                            data = {handle = handle, steps = #(rows as {any}), clock = clock},
                        }
                    end,
                },
                {
                    name = "status",
                    shortHelp = "where a playback sits and what it will do next",
                    schema = handleSchema,
                    outputSchema = {
                        type = "object",
                        properties = {
                            handle = {type = "integer"},
                            state = {type = "string"},
                            pc = {type = "integer"},
                            upcoming = {type = "array", items = {type = "object"}},
                        },
                        required = {"handle", "state", "pc"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local handle <const> = math.floor(v.handle as number)
                        local data <const> = statusData(w, handle)
                        if not data then
                            return {ok = false, code = "no_playback",
                                message = "program status: no playback " .. tostring(handle)}
                        end
                        local popup: {string} = {
                            format("playback %d\t%s v%d", handle,
                                data.program as string, data.version as integer),
                            "  state\t" .. (data.state as string),
                            "  pc\t" .. tostring(data.pc),
                        }
                        local ahead <const> = data.upcoming as {{string: any}}
                        for i = 1, math.min(#ahead, 12) do
                            popup[#popup + 1] = format("  +%d\t%s %s",
                                ahead[i]["in"] as integer, ahead[i].kind as string,
                                ahead[i].name as string)
                        end
                        return {ok = true, popup = popup, data = data}
                    end,
                },
                {
                    name = "cancel",
                    shortHelp = "stop a playback and its branches",
                    schema = handleSchema,
                    annotations = {readOnlyHint = false, destructiveHint = true,
                        idempotentHint = true, openWorldHint = false},
                    outputSchema = {
                        type = "object",
                        properties = {
                            handle = {type = "integer"},
                            cancelled = {type = "boolean"},
                        },
                        required = {"handle", "cancelled"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local handle <const> = math.floor(v.handle as number)
                        local cancelled <const> = sequence.cancel(w, handle)
                        return {
                            ok = true,
                            message = cancelled
                                and ("cancelled " .. tostring(handle))
                                or ("nothing running as " .. tostring(handle)),
                            data = {handle = handle, cancelled = cancelled},
                        }
                    end,
                },
            },
        },
    }
end

return programcmds
