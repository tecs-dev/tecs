--- tecs2d.mcp: MCP integration for tecs games.
--- Provides an HTTP server implementing the MCP Streamable HTTP transport.
---
--- Usage:
---   local mcp = require("tecs2d.mcp")
---   world:addPlugin(mcp.new())              -- default port 19999
---   world:addPlugin(mcp.new({port = 12345})) -- custom port
---
--- Without an explicit port, the TECS_MCP_PORT environment variable is
--- honored so test harnesses can assign a free port per game instance.
---
--- The plugin ensures the headless debugger core (see tecs2d.debug.context),
--- so the registry-derived cmd_* command tools (cmd_context,
--- cmd_capabilities, ...) work in every session; the debug plugin
--- (require("tecs2d.debug").new()) adds the in-game overlay on top of the
--- same core. Set debugCore = false to ensure only the freeze controller.
---
--- End users configure Claude Code with: {"type":"http","url":"http://localhost:19999/mcp"}
---
--- Server internals live under tecs2d.mcp.internal: state (shared context),
--- logtap (log capture ring), transport (sockets and HTTP framing), rpc
--- (JSON-RPC envelope and tool dispatch), and handlers (the kernel tools)
--- registering into rpc.handlers.

local tecs <const> = require("tecs")
local buildinfo <const> = require("tecs2d.buildinfo")
local logging <const> = require("tecs.utils.logging")
local mcpTools <const> = require("tecs2d.mcp.tools")
local debugapi <const> = require("tecs2d.debug.context")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local state <const> = require("tecs2d.mcp.internal.state")
local logtap <const> = require("tecs2d.mcp.internal.logtap")
local transport <const> = require("tecs2d.mcp.internal.transport")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local handlers <const> = require("tecs2d.mcp.internal.handlers")

local record mcp
    record Config
        port: number

        --- Ensure the headless debugger core (context, command registry,
        --- freeze, annotations, recorder) so the cmd_* tools work without
        --- the debug plugin. Default true; false ensures only the freeze
        --- controller.
        debugCore: boolean

        --- Keep the MCP server in builds packaged by `tecs dist`. By default
        --- the plugin is a no-op when tecs2d.buildinfo reports a distributed
        --- build.
        enableInDist: boolean
    end
    new: function(config?: Config): function(world: tecs.World)
    DEFAULT_PORT: integer
end

mcp.DEFAULT_PORT = 19999

function mcp.new(config?: mcp.Config): function(world: tecs.World)
    -- Distributed builds do not serve MCP unless the game opts in.
    if not buildinfo.isDev() and not (config and config.enableInDist) then
        logging.getLogger("tecs-mcp"):info("MCP server disabled in this distributed build; " ..
            "pass enableInDist to mcp.new() to keep it")
        return function(_world: tecs.World) end
    end

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
    handlers.install(ctx)

    -- TECS_MCP_PORT lets test harnesses (tecs2d.testing.fixture, `tecs
    -- integ`) assign a free port without the game wiring one explicitly.
    local port = (config and config.port)
        or tonumber(os.getenv("TECS_MCP_PORT"))
        or mcp.DEFAULT_PORT
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
            -- The registry's restart command calls this before quitting so
            -- the connection aborts with RST and the restarted instance can
            -- rebind the port immediately (see the transport's close rules).
            prepareRestart = function()
                ctx.rstOnClose = true
            end,
        }

        -- The run_lua sandbox, callable by debugger commands (cmd_step's
        -- `lua` post-step read) without a dependency on this module.
        w.resources[mcpinfo.LUA_EVAL] = handlers.evalInSandbox

        -- The MCP frame systems run in RenderFirst, not a gameplay phase:
        -- a freeze disables the gameplay phases (First..Last), and the server
        -- must keep answering cmd_freeze/cmd_step/run_lua while frozen.
        -- RenderFirst also runs
        -- before the render pipeline's PreRender sync, so world ops drained this
        -- frame render this frame; the component-dirty bits they set would
        -- otherwise be cleared at the end of world:update before the next sync
        -- could see them.
        --
        -- The debugger core (shared with the debug plugin) carries the command
        -- registry, freeze controller, and the always-on rewind/screenshot/
        -- recording systems; ensuring it here keeps the cmd_* tools and
        -- freeze/step working with or without the debug plugin. debugCore =
        -- false narrows this to the freeze controller alone.
        if config and config.debugCore == false then
            debugapi.ensureFreeze(w)
        else
            debugapi.ensureCore(w)
        end

        -- Boot frozen when asked (TECS_BOOT_FROZEN=1, set by the bridge's
        -- start_game {frozen:true}): the freeze is acquired before the first
        -- frame, so the game is inspectable at frame zero instead of racing
        -- the operator's cmd_freeze. Startup phases still run (the freeze
        -- only disables the gameplay group). Held as "operator" -- the same
        -- hold cmd_freeze manages -- so cmd_freeze on=false releases it.
        if os.getenv("TECS_BOOT_FROZEN") == "1" then
            debugapi.ensureFreeze(w):acquire("operator")
        end

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
