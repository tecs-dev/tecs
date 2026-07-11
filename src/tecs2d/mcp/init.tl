--- tecs2d.mcp: MCP integration for tecs games.
--- Provides an HTTP server implementing the MCP Streamable HTTP transport.
---
--- Usage:
---   local mcp = require("tecs2d.mcp")
---   world:addPlugin(mcp.new())              -- default port 19999
---   world:addPlugin(mcp.new({port = 12345})) -- custom port
---
--- The in-game debugger overlay lives in the debug plugin
--- (require("tecs2d.debug").new()); the get_debug_context tool reads the
--- DebugContext resource that plugin publishes, and the debugger's command
--- registry is projected as debug_* tools (see tecs2d.debug.context).
---
--- End users configure Claude Code with: {"type":"http","url":"http://localhost:19999/mcp"}
---
--- Server internals live under tecs2d.mcp.internal: state (shared context),
--- logtap (log capture ring), transport (sockets and HTTP framing), rpc
--- (JSON-RPC envelope and tool dispatch), and the handler modules
--- (enginetools, worldtools, snapshots, profiler) that register their tools
--- into rpc.handlers.

local tecs <const> = require("tecs")
local mcpTools <const> = require("tecs2d.mcp.tools")
local debugapi <const> = require("tecs2d.debug.context")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local state <const> = require("tecs2d.mcp.internal.state")
local logtap <const> = require("tecs2d.mcp.internal.logtap")
local transport <const> = require("tecs2d.mcp.internal.transport")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local enginetools <const> = require("tecs2d.mcp.internal.enginetools")
local worldtools <const> = require("tecs2d.mcp.internal.worldtools")
local snapshots <const> = require("tecs2d.mcp.internal.snapshots")
local profiler <const> = require("tecs2d.mcp.internal.profiler")

local record mcp
    record Config
        port: number
    end
    new: function(config?: Config): function(world: tecs.World)
    DEFAULT_PORT: integer
end

mcp.DEFAULT_PORT = 19999

function mcp.new(config?: mcp.Config): function(world: tecs.World)
    -- The MCP server is a process-global singleton: server socket, world
    -- pointer, pause state, and screenshot state all live in module-level
    -- state. A second mcp.new() would silently stomp the first (second
    -- server, shared state races between the two worlds). Detect and reject
    -- duplicate initialization with a clear error. After a failed initial
    -- bind, the server socket is nil while the background rebinder is still
    -- active; that still counts as an initialized server.
    if transport.isActive() then
        error("tecs2d.mcp.new() already called; only one MCP server can be active per process. " ..
              "The previous server is still bound to port " .. tostring(transport.getBoundPort()) .. ".")
    end

    local ctx <const> = state.new()
    transport.install(ctx)
    rpc.install(ctx)
    enginetools.install(ctx)
    worldtools.install(ctx)
    snapshots.install(ctx)
    profiler.install(ctx)

    local port = (config and config.port) or mcp.DEFAULT_PORT
    logtap.install()
    transport.startServer(port)

    return function(w: tecs.World)
        ctx.world = w

        -- Session info for the debugger's `agent` command.
        w.resources[mcpinfo.KEY] = {
            port = function(): integer
                return (transport.getBoundPort() or 0) as integer
            end,
            toolCount = function(): integer
                local n = #mcpTools.list
                local derived = debugapi.commandTools(w)
                if derived then n = n + #derived end
                return n
            end,
        }

        -- The MCP frame systems run in RenderFirst, not a gameplay phase:
        -- pause disables the gameplay phases (First..Last), and the server must
        -- keep answering resume/step/run_lua while paused. RenderFirst also runs
        -- before the render pipeline's PreRender sync, so world ops drained this
        -- frame render this frame; the component-dirty bits they set would
        -- otherwise be cleared at the end of world:update before the next sync
        -- could see them.
        --
        -- The freeze controller (shared with the debugger overlay) installs its
        -- own step-counting system; ensuring it here keeps pause/step working
        -- with or without the debug plugin.
        debugapi.ensureFreeze(w)

        w:addSystem({
            name = "mcp.ProcessCommands",
            -- Process MCP HTTP requests and enqueue world ops for same-frame
            -- execution by `mcp.DrainQueuedOps`. See the RenderFirst rationale
            -- above.
            phase = tecs.phases.RenderFirst,
            before = {"mcp.DrainQueuedOps"},
            run = function()
                transport.processCommands(rpc.processMessage)
            end
        })

        w:addSystem({
            name = "mcp.DrainQueuedOps",
            phase = tecs.phases.RenderFirst,
            run = function(_dt: number, ww: tecs.World)
                state.drain(ctx, ww)
            end
        })

        w:addSystem({
            name = "mcp.Cleanup",
            phase = tecs.phases.Shutdown,
            run = function()
                ctx.queuedWorldOps = {}
                transport.cleanup()
            end
        })
    end
end

return mcp
