--- Running sequencer programs from the debugger.
---
--- One tool plays and inspects sequencer programs -- input, waits, spawns, tween
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

local programSchema <const>: cmdargs.Schema = {
    args = {
        name = {required = true, help = "program name (see `program defined`)"},
        version = {kind = "number", help = "program version; newest if omitted"},
    },
    positional = {"name", "version"},
}
cmdargs.validate(programSchema)

local signalSchema <const>: cmdargs.Schema = {
    args = { name = {required = true, help = "signal name"} },
    positional = {"name"},
}
cmdargs.validate(signalSchema)

-- One line of "why is this playback not running", in the order a reader
-- asks: a wait time, a signal, a query, or its branches.
local function blockedOn(s: sequence.Status): string
    if s.waitingFor then return "signal " .. s.waitingFor end
    if s.waitingQuery then
        return format("query %s %s", s.waitingQuery, s.waitingCondition)
    end
    if s.joining then return format("%d branch(es)", s.branches) end
    if s.wakeAt then return "step " .. tostring(s.wakeAt) end
    return "-"
end

local function statusRow(handle: integer, s: sequence.Status): {string: any}
    return {
        handle = handle,
        program = s.program,
        version = s.version,
        pc = s.pc,
        state = s.state,
        wakeAt = s.wakeAt,
        waitingFor = s.waitingFor,
        waitingQuery = s.waitingQuery,
        waitingCondition = s.waitingCondition,
        branches = s.branches,
        joining = s.joining,
        fault = s.fault,
        faultMessage = s.faultMessage,
    }
end

function programcmds.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world
    registerEditActions(w, d.componentFor)
    inputtape.ensure(w)

    local function listPlaybacks(): cmdtypes.Result
        local handles = sequence.playbacks(w)
        local rows: {{string: any}} = {}
        local popup: {string} = {
            format("sequences  (%d live, step %d):",
                #handles, sequence.currentStep(w)),
        }
        for i = 1, #handles do
            local s = sequence.status(w, handles[i])
            if s then
                rows[#rows + 1] = statusRow(handles[i], s)
                popup[#popup + 1] = format("  %d\t%s v%d\tpc %d\t%s\t%s",
                    handles[i], s.program, s.version, s.pc, s.state, blockedOn(s))
            end
        end
        if #rows == 0 then popup[#popup + 1] = "  (none)" end
        return {ok = true, popup = popup,
            data = {count = #rows, step = sequence.currentStep(w), playbacks = rows}}
    end


    return {
        {
            name = "program",
            section = "Session",
            shortHelp = "play and inspect sequencer programs",
            mcpHelp = "Play a sequencer program given as data, and get a handle back. A program is a list of steps -- "
                .. table.concat(sequence.dataOps(), ", ")
                .. ", plus `input` for love events -- which run in order on a clock, so a scenario is scheduled rather "
                .. "than fired all at once. Unlike run_lua it survives a snapshot: save mid-program and the load "
                .. "resumes at the same step. `status` reports where one playback sits, what blocks it, and its "
                .. "disassembly with the pc marked; `list` reports every live playback; `defined` and `disasm` read "
                .. "the compiled programs themselves; `signal` wakes the playbacks blocked on a name; `cancel` stops "
                .. "a playback and its branches.",
            examples = {
                'program play [{"op":"input","event":"keypressed","args":["space"]},{"op":"wait","seconds":0.5}] clock=frame',
                'program play [{"op":"call","action":"game.spawnWave"},{"op":"waitQuery","query":"game.adds","condition":"empty"}]',
                "program status 1048577",
                "program cancel 1048577",
                "program list",
                "program defined",
                "program disasm game.bossIntro",
                "program signal adds.cleared",
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
                    shortHelp = "where a playback sits, what blocks it, what it does next",
                    schema = handleSchema,
                    outputSchema = {
                        type = "object",
                        properties = {
                            handle = {type = "integer"},
                            state = {type = "string"},
                            pc = {type = "integer"},
                            upcoming = {type = "array", items = {type = "object"}},
                            disassembly = {type = "string",
                                description = "the program, with pc marked"},
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
                        local status <const> = sequence.status(w, handle)
                        local popup: {string} = {
                            format("playback %d\t%s v%d", handle,
                                data.program as string, data.version as integer),
                            "  state\t" .. (data.state as string),
                            "  pc\t" .. tostring(data.pc),
                            "  blocked on\t" .. blockedOn(status),
                        }
                        if status.fault then
                            popup[#popup + 1] = "  fault\t" .. status.fault
                            popup[#popup + 1] = "  message\t" .. tostring(status.faultMessage)
                        end
                        local ahead <const> = data.upcoming as {{string: any}}
                        for i = 1, math.min(#ahead, 12) do
                            popup[#popup + 1] = format("  +%d\t%s %s",
                                ahead[i]["in"] as integer, ahead[i].kind as string,
                                ahead[i].name as string)
                        end
                        -- The playback may be running a superseded version,
                        -- which is exactly the case worth reading carefully.
                        local prog <const> = sequence.program(
                            status.program, status.version)
                        if prog then
                            local text <const> = sequence.disassemble(prog, status.pc)
                            data.disassembly = text
                            popup[#popup + 1] = ""
                            for line in text:gmatch("[^\n]+") do
                                popup[#popup + 1] = line
                            end
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
                {
                    name = "list",
                    shortHelp = "list live playbacks and what each is waiting on",
                    outputSchema = {
                        type = "object",
                        properties = {
                            count = {type = "integer", description = "live playbacks"},
                            step = {type = "integer",
                                description = "fixed step the sequencer has reached"},
                            playbacks = {type = "array", items = {type = "object"}},
                        },
                        required = {"count", "step"},
                    },
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        return listPlaybacks()
                    end,
                },
                {
                    name = "defined",
                    shortHelp = "list defined programs and their newest version",
                    outputSchema = {
                        type = "object",
                        properties = {
                            count = {type = "integer"},
                            programs = {type = "array", items = {type = "object"}},
                        },
                        required = {"count"},
                    },
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local names = sequence.programNames()
                        local rows: {{string: any}} = {}
                        local popup: {string} = {
                            format("programs defined  (%d):", #names),
                        }
                        for i = 1, #names do
                            local prog = sequence.program(names[i])
                            rows[i] = {name = names[i], version = prog.version}
                            popup[#popup + 1] = format("  %s\tv%d", names[i], prog.version)
                        end
                        if #names == 0 then popup[#popup + 1] = "  (none)" end
                        return {ok = true, popup = popup,
                            data = {count = #names, programs = rows}}
                    end,
                },
                {
                    name = "disasm",
                    shortHelp = "disassemble a program by name",
                    schema = programSchema,
                    outputSchema = {
                        type = "object",
                        properties = {
                            name = {type = "string"},
                            version = {type = "integer"},
                            disassembly = {type = "string"},
                        },
                        required = {"name", "version", "disassembly"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local name = v.name as string
                        local wanted = v.version and math.floor(v.version as number) or nil
                        local prog = sequence.program(name, wanted)
                        if not prog then
                            return {ok = false, code = "no_program",
                                message = "program disasm: no program '" .. name .. "'"
                                    .. (wanted and (" v" .. tostring(wanted)) or "")}
                        end
                        local text = sequence.disassemble(prog)
                        local popup: {string} = {}
                        for line in text:gmatch("[^\n]+") do
                            popup[#popup + 1] = line
                        end
                        return {ok = true, popup = popup, data = {
                            name = prog.name, version = prog.version, disassembly = text}}
                    end,
                },
                {
                    name = "signal",
                    shortHelp = "raise a named signal, waking the playbacks blocked on it",
                    schema = signalSchema,
                    annotations = {readOnlyHint = false, destructiveHint = false,
                        idempotentHint = false, openWorldHint = false},
                    outputSchema = {
                        type = "object",
                        properties = {
                            name = {type = "string"},
                            woken = {type = "integer",
                                description = "playbacks that will wake next step"},
                        },
                        required = {"name", "woken"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local name = v.name as string
                        local woken = sequence.signal(w, name)
                        return {
                            ok = true,
                            message = format("signalled %s, waking %d next step", name, woken),
                            data = {name = name, woken = woken},
                        }
                    end,
                },
            },
        },
    }
end

return programcmds
