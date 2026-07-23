--- Shared MCP server context threaded through every MCP module: the lazily
--- bound world pointer, the queued world-op list, and the in-flight response
--- flags the transport consults before closing a client socket.

local tecs <const> = require("tecs")

local record state
    record Context
        --- Bound when the plugin closure runs; tools that need the world
        --- report world_unavailable until then.
        world: tecs.World
        --- Ops that must run inside the frame's world update; drained by
        --- the mcp.DrainQueuedOps system.
        queuedWorldOps: {function(tecs.World)}
        --- Tool id of an in-flight screenshot. The capture callback answers
        --- a frame later, so the client socket stays open until it clears.
        pendingScreenshotId: string | number
        --- True while a queued world op (run_lua) still owes the client a
        --- deferred response; keeps the socket open like a screenshot.
        pendingWorldOpResponse: boolean
        --- Traceback of a gameplay crash. When set, tools/call answers
        --- game_crashed (ping and get_logs still work) while the error
        --- screen keeps pumping the transport.
        crashed: string
        --- When set, the next client close aborts the connection with
        --- linger 0 (RST) instead of a FIN close. The MCP plugin's
        --- prepareRestart hook sets this: a normal close leaves the
        --- accepted socket in
        --- FIN_WAIT/TIME_WAIT, which can block rebinding the same port for
        --- many seconds after the engine restarts (SO_REUSEADDR does not
        --- bypass FIN_WAIT states).
        rstOnClose: boolean
    end

    new: function(): Context
    enqueue: function(ctx: Context, op: function(tecs.World))
    drain: function(ctx: Context, w: tecs.World)
end

local MAX_QUEUED_OP_PASSES <const> = 10

function state.new(): state.Context
    return {
        queuedWorldOps = {},
        pendingWorldOpResponse = false,
        rstOnClose = false,
    }
end

function state.enqueue(ctx: state.Context, op: function(tecs.World))
    ctx.queuedWorldOps[#ctx.queuedWorldOps + 1] = op
end

function state.drain(ctx: state.Context, w: tecs.World)
    local pass = 0
    while #ctx.queuedWorldOps > 0 and pass < MAX_QUEUED_OP_PASSES do
        pass = pass + 1
        local ops = ctx.queuedWorldOps
        ctx.queuedWorldOps = {}
        for i = 1, #ops do
            ops[i](w)
        end
        w:commit()
    end
end

return state
