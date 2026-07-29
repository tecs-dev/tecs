--[=[
Programs as plain data.

The node constructors are Lua functions, which an agent on the other end
of an MCP connection cannot call. This is the same authoring surface as a
list of objects, so a program can be sent over the wire, stored in a file,
or written by hand:

    {
      {op = "call", action = "game.lockControls"},
      {op = "wait", seconds = 1.5},
      {op = "parallel", blocks = {
          {{op = "playTween", preset = "boss.enter", bind = "boss"},
           {op = "waitTween"}},
          {{op = "waitQuery", query = "game.adds", condition = "empty"}},
      }},
      {op = "emit", event = "boss.ready"},
    }

Decoding validates as it goes and reports the path to a bad entry, since
the author is usually a tool and the message is all it gets.
]=]

local seqtypes <const> = require("tecs.sequence.internal.types")

local record json
    --- Node constructors this codec builds against. Injected rather than
    --- required, because they live in the public module that requires this
    --- one.
    record Builders
        call: function(action: string, ...: any): seqtypes.Node
        wait: function(seconds: number): seqtypes.Node
        waitSteps: function(steps: integer): seqtypes.Node
        waitSignal: function(name: string): seqtypes.Node
        waitQuery: function(name: string, condition: seqtypes.QueryCondition): seqtypes.Node
        emit: function(event: string, ...: any): seqtypes.Node
        loop: function(count: integer, nodes: {seqtypes.Node}): seqtypes.Node
        fork: function(nodes: {seqtypes.Node}): seqtypes.Node
        join: function(): seqtypes.Node
        parallel: function(...: {seqtypes.Node}): seqtypes.Node
        playTween: function(preset: string, target: seqtypes.EntityRef, options?: any): seqtypes.Node
        waitTween: function(): seqtypes.Node
        bind: function(name: string): seqtypes.EntityRef
    end

    --- Turn a list of plain objects into nodes, or nil plus the path and
    --- reason of the first entry that is not one.
    decode: function(b: Builders, rows: {any}): {seqtypes.Node}, string

    --- The op names `decode` accepts, sorted. For help text and tool schemas.
    ops: function(): {string}
end

local OPS <const>: {string} = {
    "call",
    "emit",
    "fork",
    "join",
    "loop",
    "parallel",
    "playTween",
    "wait",
    "waitQuery",
    "waitSignal",
    "waitSteps",
    "waitTween",
}

-- A `bind` reference is the one argument that is not a plain constant, so it
-- travels as {bind = "name"} and is rebuilt here.
local function decodeArgs(b: json.Builders, raw: {any}): {any}
    local out: {any} = {}
    for i = 1, #(raw or {}) do
        local value = raw[i]
        if value is table then
            local ref = value as {string: any}
            if ref.bind ~= nil then
                out[i] = b.bind(ref.bind as string)
            else
                out[i] = value
            end
        else
            out[i] = value
        end
    end
    return out
end

local decodeList: function(b: json.Builders, rows: {any}, path: string): {seqtypes.Node}, string

local function decodeOne(b: json.Builders, row: {string: any}, path: string): seqtypes.Node, string
    local op <const> = row.op
    if not (op is string) then
        return nil, path .. ": every entry needs an `op` naming what it does"
    end

    if op == "call" then
        local action = row.action
        if not (action is string) then
            return nil, path .. ": call needs `action`"
        end
        return b.call(action, table.unpack(decodeArgs(b, row.args as {any})))
    elseif op == "emit" then
        local event = row.event
        if not (event is string) then
            return nil, path .. ": emit needs `event`"
        end
        return b.emit(event, table.unpack(decodeArgs(b, row.args as {any})))
    elseif op == "wait" then
        local seconds = row.seconds
        if not (seconds is number) then
            return nil, path .. ": wait needs `seconds`"
        end
        return b.wait(seconds)
    elseif op == "waitSteps" then
        local steps = row.steps
        if not (steps is number) then
            return nil, path .. ": waitSteps needs `steps`"
        end
        return b.waitSteps(math.floor(steps) as integer)
    elseif op == "waitSignal" then
        local signal = row.signal
        if not (signal is string) then
            return nil, path .. ": waitSignal needs `signal`"
        end
        return b.waitSignal(signal)
    elseif op == "waitQuery" then
        local query = row.query
        if not (query is string) then
            return nil, path .. ": waitQuery needs `query`"
        end
        local condition = row.condition as string
        if condition ~= "any" and condition ~= "empty" then
            return nil, path .. ": waitQuery `condition` must be 'any' or 'empty'"
        end
        return b.waitQuery(query, condition as seqtypes.QueryCondition)
    elseif op == "waitTween" then
        return b.waitTween()
    elseif op == "playTween" then
        local preset = row.preset
        if not (preset is string) then
            return nil, path .. ": playTween needs `preset`"
        end
        local bindName = row.bind
        if not (bindName is string) then
            return nil, path .. ": playTween needs `bind`, naming a binding"
        end
        return b.playTween(preset, b.bind(bindName), row.options)
    elseif op == "join" then
        return b.join()
    elseif op == "loop" or op == "fork" then
        local nodes, err = decodeList(b, row.nodes as {any}, path .. "." .. op)
        if not nodes then
            return nil, err
        end
        if op == "fork" then
            return b.fork(nodes)
        end
        local count = row.count as number
        return b.loop(count and math.floor(count) as integer or nil, nodes)
    elseif op == "parallel" then
        local raw = row.blocks
        if not (raw is table) or #(raw as {any}) == 0 then
            return nil, path .. ": parallel needs a non-empty `blocks` list"
        end
        local blocks: {{seqtypes.Node}} = {}
        for i = 1, #(raw as {any}) do
            local nodes, err = decodeList(b, (raw as {any})[i] as {any}, path .. ".blocks[" .. tostring(i) .. "]")
            if not nodes then
                return nil, err
            end
            blocks[i] = nodes
        end
        return b.parallel(table.unpack(blocks))
    end

    return nil, path .. ": unknown op '" .. op .. "' (expected one of " .. table.concat(OPS, ", ") .. ")"
end

decodeList = function(b: json.Builders, rows: {any}, path: string): {seqtypes.Node}, string
    if not (rows is table) then
        return nil, path .. ": expected a list of steps"
    end
    local list <const> = rows as {any}
    local out: {seqtypes.Node} = {}
    for i = 1, #list do
        local entry = list[i]
        if not (entry is table) then
            return nil, path .. "[" .. tostring(i) .. "]: expected an object"
        end
        local node, err = decodeOne(b, entry as {string: any}, path .. "[" .. tostring(i) .. "]")
        if not node then
            return nil, err
        end
        out[i] = node
    end
    return out, nil
end

function json.decode(b: json.Builders, rows: {any}): {seqtypes.Node}, string
    -- Authoring an empty program is almost always a mistake in the caller.
    if rows is table and #(rows as {any}) == 0 then
        return nil, "program: needs at least one step"
    end
    return decodeList(b, rows, "program")
end

function json.ops(): {string}
    local out: {string} = {}
    for i = 1, #OPS do
        out[i] = OPS[i]
    end
    return out
end

return json
