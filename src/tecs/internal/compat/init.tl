-- Compatibility shims loaded by the public tecs entry point.
if not table.unpack then
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

require("tecs.internal.compat.jitzone")
require("tecs.internal.compat.jitvmdef")

return true
