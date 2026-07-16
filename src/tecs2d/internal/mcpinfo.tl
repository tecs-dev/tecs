--- Session info the MCP plugin publishes for the debugger's `agent` command.
--- Closures (rather than values) because the port can bind late after an
--- engine restart, and the tool count grows as commands register.

local tecs <const> = require("tecs")

local record mcpinfo
    record Info
        --- The bound MCP port, or 0 while binding is still pending.
        port: function(): integer
        --- Total MCP tools currently exposed (kernel + registry-derived).
        toolCount: function(): integer
        --- Marks the live MCP connection for an RST close so a restarted
        --- instance can rebind the port immediately. The registry's restart
        --- command calls it before love.event.quit("restart").
        prepareRestart: function()
    end

    KEY: tecs.Key<Info>

    --- Installed by the MCP plugin: evaluates code in the run_lua sandbox and
    --- returns (true, {returned=n, values={...}}) or (false, error message).
    --- Published as a resource so debugger commands (cmd_step's `lua` read)
    --- share the one hardened sandbox without depending on the mcp module.
    LUA_EVAL: tecs.Key<function(string, tecs.World): boolean, any>
end

mcpinfo.KEY = tecs.newKey("tecs2d.mcp.info")
mcpinfo.LUA_EVAL = tecs.newKey("tecs2d.mcp.luaeval")

return mcpinfo
