-- Basic Lua compatibility layer
if not table.unpack then
    -- Ensure table has an unpack function.
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

require("tecs.internal.compat.jitzone")
require("tecs.internal.compat.jitvmdef")

return true
