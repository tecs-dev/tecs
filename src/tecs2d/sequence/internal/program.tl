--- The sequencer's compiler and disassembler.
---
--- A program is a flat integer array with stride 3 -- (op, a, b) -- over a
--- const pool, which is what makes it serializable: a saved program carries
--- its own instructions rather than a reference to the Lua that built it.
--- The opcodes live here because the VM interprets what this module emits.

local seqtypes <const> = require("tecs2d.sequence.internal.types")

local floor <const> = math.floor

local type NodeImpl = seqtypes.NodeImpl
local type ProgramImpl = seqtypes.ProgramImpl
local type EntityRef = seqtypes.EntityRef
local type Node = seqtypes.Node

local record program
    --- Instruction opcodes, and the (op, a, b) stride of the code array.
    WAIT: integer
    CALL: integer
    EMIT: integer
    JUMP: integer
    END: integer
    WAIT_SIGNAL: integer
    FORK: integer
    JOIN: integer
    WAIT_QUERY: integer
    PLAY_TWEEN: integer
    WAIT_TWEEN: integer
    STRIDE: integer

    --- Whether a value is a `bind(name)` reference. Shared by the compiler,
    --- the VM's argument resolution, and the disassembler.
    isEntityRef: function(value: any): boolean

    --- Compile authored nodes into a program under `name` at `version`.
    compile: function(name: string, version: integer, nodes: {Node}): ProgramImpl

    --- Mark the argument lists that hold a `bind` reference. Derived rather
    --- than stored: a restored program computes the same from its consts.
    indexBindingArgs: function(prog: ProgramImpl)

    --- Render a program as readable instructions, marking a pc.
    disassemble: function(prog: ProgramImpl, pc?: integer): string
end

-- Instruction opcodes. Code is a flat array with stride 3: (op, a, b).
local OP_WAIT <const> = 1     -- a = const index holding seconds, or -1
                              -- b = literal step count when a is -1
local OP_CALL <const> = 2     -- a = const index of action name
                              -- b = const index of args array
local OP_EMIT <const> = 3     -- a = const index of event name
                              -- b = const index of args array
local OP_JUMP <const> = 4     -- a = target pc
                              -- b = loop register, or -1 for unconditional
local OP_END <const> = 5
local OP_WAIT_SIGNAL <const> = 6  -- a = const index of signal name
local OP_FORK <const> = 7     -- a = first pc of the branch body
                              -- b = pc the forking cursor continues at
local OP_JOIN <const> = 8
local OP_WAIT_QUERY <const> = 9   -- a = const index of query name
                                  -- b = 1 to wait for a match, 0 for none
local OP_PLAY_TWEEN <const> = 10  -- a = const index of preset name
                                  -- b = const index of {bind, options}
local OP_WAIT_TWEEN <const> = 11

local STRIDE <const> = 3

local function isEntityRef(value: any): boolean
    if type(value) ~= "table" then return false end
    local ref = value as EntityRef
    return ref.isBinding == true and type(ref.bindName) == "string"
end

local record Compiler
    code: {integer}
    consts: {any}
    constIndex: {any: integer}
    loopSlots: integer
    loopCounts: {integer: integer}
end

local function intern(c: Compiler, value: any): integer
    -- Only scalars can be deduplicated by value; tables are appended as-is.
    if type(value) ~= "table" then
        local existing = c.constIndex[value]
        if existing then return existing end
    end
    local index = #c.consts + 1
    c.consts[index] = value
    if type(value) ~= "table" then
        c.constIndex[value] = index
    end
    return index
end

local function emitOp(c: Compiler, op: integer, a: integer, b: integer): integer
    local pc = floor(#c.code / STRIDE)
    c.code[#c.code + 1] = op
    c.code[#c.code + 1] = a
    c.code[#c.code + 1] = b
    return pc
end

local compileBlock: function(c: Compiler, nodes: {Node}, depth: integer)

-- A branch body is laid out inline, between the fork and the instruction the
-- forking cursor continues at, and terminated by its own END. One program
-- holds the whole tree, so a snapshot carries one program and a disassembly
-- shows every branch in place.
local function compileFork(c: Compiler, nodes: {Node}, depth: integer)
    local forkPc = emitOp(c, OP_FORK, 0, 0)
    c.code[forkPc * STRIDE + 2] = forkPc + 1
    compileBlock(c, nodes, depth)
    emitOp(c, OP_END, -1, -1)
    c.code[forkPc * STRIDE + 3] = floor(#c.code / STRIDE)
end

local function compileNode(c: Compiler, node: NodeImpl, depth: integer)
    local kind = node.kind
    if kind == "call" then
        emitOp(c, OP_CALL, intern(c, node.text), intern(c, node.args))
    elseif kind == "emit" then
        emitOp(c, OP_EMIT, intern(c, node.text), intern(c, node.args))
    elseif kind == "wait" then
        emitOp(c, OP_WAIT, intern(c, node.number), -1)
    elseif kind == "waitSignal" then
        emitOp(c, OP_WAIT_SIGNAL, intern(c, node.text), -1)
    elseif kind == "waitQuery" then
        emitOp(c, OP_WAIT_QUERY, intern(c, node.text), node.count)
    elseif kind == "waitSteps" then
        emitOp(c, OP_WAIT, -1, node.number as integer)
    elseif kind == "loop" then
        local slot = depth + 1
        if slot > c.loopSlots then c.loopSlots = slot end
        local top = floor(#c.code / STRIDE)
        compileBlock(c, node.nodes, slot)
        -- A nil count loops forever; the register is unused in that case.
        local jumpPc = emitOp(c, OP_JUMP, top, node.count and slot or -1)
        -- Counts are keyed by the jump's own pc, so a cursor reaching that
        -- jump for the first time knows what to seed its register with.
        if node.count then c.loopCounts[jumpPc] = node.count end
    elseif kind == "fork" then
        compileFork(c, node.nodes, depth)
    elseif kind == "playTween" then
        emitOp(c, OP_PLAY_TWEEN, intern(c, node.text), intern(c, node.args))
    elseif kind == "waitTween" then
        emitOp(c, OP_WAIT_TWEEN, -1, -1)
    elseif kind == "join" then
        emitOp(c, OP_JOIN, -1, -1)
    elseif kind == "parallel" then
        local blocks = node.blocks
        for i = 1, #blocks do
            compileFork(c, blocks[i], depth)
        end
        emitOp(c, OP_JOIN, -1, -1)
    else
        error("sequence: unknown node kind '" .. tostring(kind) .. "'")
    end
end

compileBlock = function(c: Compiler, nodes: {Node}, depth: integer)
    for i = 1, #nodes do
        local node = nodes[i] as NodeImpl
        if type(node) ~= "table" or node.kind == nil then
            error("sequence: entry " .. tostring(i) .. " is not a sequence node")
        end
        compileNode(c, node, depth)
    end
end

-- Mark the argument lists that need resolving. Derived rather than stored:
-- a restored program computes the same thing from its own const pool.
function program.indexBindingArgs(prog: ProgramImpl)
    local flags: {integer: boolean} = {}
    local consts = prog.consts
    for i = 1, #consts do
        local value = consts[i]
        if type(value) == "table" then
            local list = value as {any}
            for j = 1, #list do
                if isEntityRef(list[j]) then
                    flags[i] = true
                    break
                end
            end
        end
    end
    prog.bindingArgs = flags
end

--- Compile authored nodes into a program under `name` at `version`.
function program.compile(
    name: string,
    version: integer,
    nodes: {Node}
): ProgramImpl
    local c: Compiler = {
        code = {},
        consts = {},
        constIndex = {},
        loopSlots = 0,
        loopCounts = {},
    }
    compileBlock(c, nodes, 0)
    emitOp(c, OP_END, -1, -1)

    local prog: ProgramImpl = {
        name = name,
        version = version,
        code = c.code,
        consts = c.consts,
        loopSlots = c.loopSlots,
        loopCounts = c.loopCounts,
        bindingArgs = {},
    }
    program.indexBindingArgs(prog)
    return prog
end

local function describeArgs(args: {any}): string
    if not args or #args == 0 then return "" end
    local parts: {string} = {}
    for i = 1, #args do
        local value = args[i]
        if isEntityRef(value) then
            parts[#parts + 1] = "bind(" .. (value as EntityRef).bindName .. ")"
        elseif type(value) == "string" then
            parts[#parts + 1] = string.format("%q", value as string)
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    return ", " .. table.concat(parts, ", ")
end

function program.disassemble(prog: ProgramImpl, pc?: integer): string
    local out: {string} = {
        string.format("%s v%d  (%d instructions)",
            prog.name, prog.version, floor(#prog.code / STRIDE)),
    }
    local counts = prog.loopCounts
    local marked = pc
    for at = 0, floor(#prog.code / STRIDE) - 1 do
        local base = at * STRIDE
        local op = prog.code[base + 1]
        local a = prog.code[base + 2]
        local b = prog.code[base + 3]
        local text: string
        if op == OP_WAIT then
            text = a >= 0
                and string.format("WAIT      %ss", tostring(prog.consts[a]))
                or string.format("WAIT      %d step(s)", b)
        elseif op == OP_WAIT_SIGNAL then
            text = string.format("WAITSIG   %q", prog.consts[a] as string)
        elseif op == OP_WAIT_QUERY then
            text = string.format("WAITQUERY %q %s",
                prog.consts[a] as string, b == 1 and "any" or "empty")
        elseif op == OP_CALL then
            text = string.format("CALL      %q%s",
                prog.consts[a] as string, describeArgs(prog.consts[b] as {any}))
        elseif op == OP_EMIT then
            text = string.format("EMIT      %q%s",
                prog.consts[a] as string, describeArgs(prog.consts[b] as {any}))
        elseif op == OP_JUMP then
            local count = counts and counts[at]
            text = string.format("JUMP      -> %d  (%s)", a,
                b < 0 and "forever" or ("x" .. tostring(count or 1)))
        elseif op == OP_FORK then
            text = string.format("FORK      branch %d..%d, continue -> %d", a, b - 1, b)
        elseif op == OP_PLAY_TWEEN then
            local spec = prog.consts[b] as {any}
            local ref = spec[1] as EntityRef
            text = string.format("PLAYTWEEN %q, bind(%s)",
                prog.consts[a] as string, ref.bindName)
        elseif op == OP_WAIT_TWEEN then
            text = "WAITTWEEN"
        elseif op == OP_JOIN then
            text = "JOIN"
        elseif op == OP_END then
            text = "END"
        else
            text = "?? " .. tostring(op)
        end
        out[#out + 1] = string.format("%s %4d  %s",
            at == marked and "->" or "  ", at, text)
    end
    return table.concat(out, "\n")
end

program.WAIT = OP_WAIT
program.CALL = OP_CALL
program.EMIT = OP_EMIT
program.JUMP = OP_JUMP
program.END = OP_END
program.WAIT_SIGNAL = OP_WAIT_SIGNAL
program.FORK = OP_FORK
program.JOIN = OP_JOIN
program.WAIT_QUERY = OP_WAIT_QUERY
program.PLAY_TWEEN = OP_PLAY_TWEEN
program.WAIT_TWEEN = OP_WAIT_TWEEN
program.STRIDE = STRIDE

program.isEntityRef = isEntityRef

return program
