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
end

mcpinfo.KEY = tecs.newKey("tecs2d.mcp.info")

return mcpinfo
