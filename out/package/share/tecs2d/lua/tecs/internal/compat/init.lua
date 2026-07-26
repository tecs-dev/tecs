
if not table.unpack then
   ((_G)["table"]).unpack = (_G)["unpack"]
end

require("tecs.internal.compat.jitzone")
require("tecs.internal.compat.jitvmdef")

return true
