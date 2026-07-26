require("busted")

local luassert <const> = require("luassert")

local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local tecs <const> = require("tecs")
local sequence <const> = require("tecs2d.sequence")

local makeRegistry <const> = cmdharness.makeRegistry

local nameCounter = 0
local function uniqueName(): string
    nameCounter = nameCounter + 1
    return "dbgseq.program" .. tostring(nameCounter)
end

describe("program debugger commands: inspection", function()
    local reg: any
    local world: tecs.World

    before_each(function()
        reg, world = makeRegistry()
        world:addPlugin(sequence.plugin)
        world:startup()
        sequence.registerAction(world, "dbgseq.noop", function() end)
    end)

    local function stepWorld(steps: integer)
        local timestep = world:getFixedTiming()
        for _ = 1, steps do world:update(timestep) end
    end

    it("lists live playbacks with what each is waiting on", function()
        local empty = reg:execute("program list")
        luassert.is_true(empty.ok)
        luassert.equals(0, empty.data.count)

        local program = sequence.define(uniqueName(), {
            sequence.waitSignal("dbgseq.gate"),
            sequence.call("dbgseq.noop"),
        })
        local handle = sequence.play(world, program)
        stepWorld(1)

        local r = reg:execute("program list")
        luassert.is_true(r.ok)
        luassert.equals(1, r.data.count)
        local rows = r.data.playbacks as {{string: any}}
        luassert.equals(handle, rows[1].handle)
        luassert.equals("dbgseq.gate", rows[1].waitingFor)
        luassert.equals(1, rows[1].pc)
    end)

    it("shows a playback's disassembly with its pc marked", function()
        local name = uniqueName()
        local program = sequence.define(name, {
            sequence.waitSteps(4),
            sequence.call("dbgseq.noop"),
        })
        local handle = sequence.play(world, program)
        stepWorld(1)

        local r = reg:execute("program status " .. tostring(handle))
        luassert.is_true(r.ok)
        luassert.equals(name, r.data.program)
        luassert.equals(1, r.data.pc)
        local text = r.data.disassembly as string
        luassert.is_truthy(text:find("->    1", 1, true),
            "the disassembly must mark the instruction the playback sits on")
    end)

    it("reports a handle it never issued", function()
        local r = reg:execute("program status 999999")
        luassert.is_false(r.ok)
        luassert.equals("no_playback", r.code)
    end)

    it("keeps reading the version a playback started with", function()
        local name = uniqueName()
        local v1 = sequence.define(name, {
            sequence.waitSteps(4),
            sequence.call("dbgseq.noop"),
        })
        local handle = sequence.play(world, v1)
        stepWorld(1)
        sequence.define(name, {sequence.call("dbgseq.noop")})

        local r = reg:execute("program status " .. tostring(handle))
        luassert.equals(1, r.data.version)
        luassert.is_truthy((r.data.disassembly as string):find("WAIT", 1, true))

        local newest = reg:execute("program disasm " .. name)
        luassert.equals(2, newest.data.version)
    end)

    it("lists and disassembles programs by name", function()
        local name = uniqueName()
        sequence.define(name, {sequence.call("dbgseq.noop")})

        local list = reg:execute("program defined")
        luassert.is_true(list.ok)
        local found = false
        for _, row in ipairs(list.data.programs as {{string: any}}) do
            if row.name == name then found = true end
        end
        luassert.is_true(found, "the defined program must appear in the listing")

        local dis = reg:execute("program disasm " .. name)
        luassert.is_true(dis.ok)
        luassert.is_truthy((dis.data.disassembly as string):find("CALL", 1, true))

        local missing = reg:execute("program disasm dbgseq.neverDefined")
        luassert.is_false(missing.ok)
        luassert.equals("no_program", missing.code)
    end)

    it("raises a signal that wakes blocked playbacks", function()
        local calls = 0
        sequence.registerAction(world, "dbgseq.count", function() calls = calls + 1 end)
        local program = sequence.define(uniqueName(), {
            sequence.waitSignal("dbgseq.gate"),
            sequence.call("dbgseq.count"),
        })
        sequence.play(world, program)
        stepWorld(1)

        local r = reg:execute("program signal dbgseq.gate")
        luassert.is_true(r.ok)
        luassert.equals(1, r.data.woken)

        stepWorld(1)
        luassert.equals(1, calls)
    end)

    it("projects every subcommand as a cmd_* tool", function()
        local names: {string: boolean} = {}
        for _, tool in ipairs(reg:mcpTools()) do names[tool.name] = true end
        luassert.is_true(names["cmd_program_list"])
        luassert.is_true(names["cmd_program_status"])
        luassert.is_true(names["cmd_program_defined"])
        luassert.is_true(names["cmd_program_disasm"])
        luassert.is_true(names["cmd_program_signal"])
        -- One group, so the old split no longer exists.
        luassert.is_nil(names["cmd_sequence_list"])
        luassert.is_nil(names["cmd_sequence_info"])
    end)
end)
