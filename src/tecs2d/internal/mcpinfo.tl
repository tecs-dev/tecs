--- Session info the MCP plugin publishes for the debugger's `agent` command.
--- Closures (rather than values) because the port can bind late after an
--- engine restart, and the tool count grows as commands register.

local tecs <const> = require("tecs")

local record mcpinfo
    record Info
        --- The bound MCP port, or 0 while binding is still pending.
        port: function(): integer
        --- Total MCP tools currently exposed (static + registry-derived).
        toolCount: function(): integer
    end

    KEY: tecs.Key<Info>
end

mcpinfo.KEY = tecs.newKey()

return mcpinfo
