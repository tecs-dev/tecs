--- JSON, which is lua-cjson with the build's own copy made reachable.
---
--- The parser and encoder are C, from `vendor/cjson`, and the build produces
--- them twice: linked into the host, where `require("cjson")` is answered from
--- `package.preload`, and as `lib/cjson.so`, which a plain interpreter has to
--- find on `package.cpath`. A command line tool built on this ECS runs the
--- second way, and the default `cpath` reaches whatever the system happens to
--- have installed rather than the copy shipped beside the Lua.
---
--- So the tree's own library directories go on the front of `cpath` before the
--- module is asked for. Ahead of the default rather than behind it: a
--- system-wide cjson of some other version otherwise answers first and the
--- pinned copy is never the one that runs. Under the host `package.preload`
--- wins whatever `cpath` says, and none of this is consulted.
---
--- The directories come from the loader, so where this build put its native
--- code is described once. Entries there carrying `%s` are `ffi.load` patterns
--- for a named dependency and match no Lua module, so they are skipped.

local loader <const> = require("tecs.ffi.loader")

--- `.so` on every platform, because that is the suffix CMake sets on the
--- module rather than the one the platform would pick.
local candidates: {string} = {}
for _, directory in ipairs(loader.searchPaths) do
    if not directory:find("%%s") then
        candidates[#candidates + 1] = directory .. "?.so"
    end
end
candidates[#candidates + 1] = package.cpath
package.cpath = table.concat(candidates, ";")

return require("cjson")
