-- Builds a shader pack from the registry.
--
-- Run at build time, on a host that has a shader compiler, to produce the
-- artifact a target without one consumes. The pack lands beside the Lua tree
-- so it sits next to the executable in an installed package.

local root = os.getenv("TECS2D_LUA") or arg[1]
if root == nil then
    io.stderr:write("usage: TECS2D_LUA=<lua dir> buildshaders.lua [output]\n")
    os.exit(1)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs2d.ffi.sdl3")
local shaderbuild = require("tecs2d.gpu.shaderbuild")
local shaderpack = require("tecs2d.gpu.shaderpack")

-- SDL_GetPlatform needs no subsystem, but the compiler paths read SDL error
-- state, so bring SDL up rather than relying on that staying true.
if not sdl.C.SDL_Init(0) then
    io.stderr:write("SDL_Init failed: " .. sdl.error() .. "\n")
    os.exit(1)
end

local output = arg[2] or (root .. "/shaders.tsp")
local ok, pack = pcall(shaderbuild.writeTo, output)
sdl.C.SDL_Quit()

if not ok then
    io.stderr:write(tostring(pack) .. "\n")
    os.exit(1)
end

local count = 0
for _ in pairs(pack.shaders) do count = count + 1 end
print(("wrote %s: %d shaders, %s"):format(
    output, count, shaderpack.formatName(pack.format)))
