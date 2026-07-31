-- Compatibility shims loaded by the public tecs entry point.
--
-- One shim, and it is a naming difference rather than a missing feature:
-- LuaJIT is a 5.1 VM, where `unpack` is a global, and everything written since
-- reaches for `table.unpack`.
if not table.unpack then
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

return true
