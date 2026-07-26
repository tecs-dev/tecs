--- Sequence debugger commands: what is playing, where each playback is
--- stopped, and what its program says.

local sequence <const> = require("tecs2d.sequence")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format

local record sequencecmds
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local handleSchema <const>: cmdargs.Schema = {
    args = { handle = {required = true, kind = "number",
        help = "playback handle (see `sequence list`)"} },
    positional = {"handle"},
}
cmdargs.validate(handleSchema)

local programSchema <const>: cmdargs.Schema = {
    args = {
        name = {required = true, help = "program name (see `sequence programs`)"},
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

function sequencecmds.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world

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
            name = "sequence",
            section = "Engine",
            shortHelp = "inspect gameplay sequences: playbacks, programs, signals",
            mcpHelp = "Inspect tecs2d.sequence playbacks. `list` reports every live playback with the instruction it sits on and what it is blocked on; `info` adds that program's disassembly with the playback's pc marked; `programs` and `disasm` read the compiled programs themselves; `signal` raises a named signal, waking the playbacks blocked on it on the next fixed step.",
            examples = {"sequence list", "sequence info 1048577",
                "sequence programs", "sequence disasm game.bossIntro",
                "sequence signal adds.cleared"},
            subcommands = {
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
                    name = "info",
                    shortHelp = "show one playback's status and disassembly",
                    schema = handleSchema,
                    outputSchema = {
                        type = "object",
                        properties = {
                            handle = {type = "integer"},
                            program = {type = "string"},
                            version = {type = "integer"},
                            pc = {type = "integer", description = "instruction it sits on"},
                            state = {type = "string"},
                            disassembly = {type = "string",
                                description = "the program, with pc marked"},
                        },
                        required = {"handle", "program", "pc", "state"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local handle = math.floor(v.handle as number)
                        local s = sequence.status(w, handle)
                        if not s then
                            return {ok = false, code = "no_playback",
                                message = "sequence info: no playback " .. tostring(handle)}
                        end
                        local data = statusRow(handle, s)
                        local popup: {string} = {
                            format("playback %d\t%s v%d", handle, s.program, s.version),
                            "  state\t" .. s.state,
                            "  pc\t" .. tostring(s.pc),
                            "  blocked on\t" .. blockedOn(s),
                        }
                        if s.fault then
                            popup[#popup + 1] = "  fault\t" .. s.fault
                            popup[#popup + 1] = "  message\t" .. tostring(s.faultMessage)
                        end
                        -- The playback may be running a superseded version,
                        -- which is exactly the case worth reading carefully.
                        local prog = sequence.program(s.program, s.version)
                        if prog then
                            local text = sequence.disassemble(prog, s.pc)
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
                    name = "programs",
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
                            format("sequence programs  (%d):", #names),
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
                                message = "sequence disasm: no program '" .. name .. "'"
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

return sequencecmds
