-- Compatibility shims loaded by the public tecs entry point.
--
-- One shim, and it is a naming difference rather than a missing feature:
-- LuaJIT is a 5.1 VM, where `unpack` is a global, and everything written since
-- reaches for `table.unpack`.
--
-- `jit.zone` and `jit.vmdef` used to be shimmed here too, and are not any more.
-- Both are ordinary Lua files that ship beside LuaJIT rather than inside it, so
-- the build copies them into the content root and `require` finds them. A
-- hand-written stand-in for `jit.vmdef` is a table of trace-abort strings
-- transcribed from one version of LuaJIT, which goes stale without saying so:
-- the pin moves, a code changes meaning, and the profiler prints the old
-- sentence with no sign that it is wrong.
if not table.unpack then
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

return true
