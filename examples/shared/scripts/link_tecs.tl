-- Post-build script: symlink engine modules into build/
os.execute("cd build && ln -sf ../../../build/tecs tecs")
os.execute("cd build && ln -sf ../../../build/tecs2d tecs2d")

-- Compile and copy standalone shared modules (floor.lua, etc.)
local sharedModules = {"floor"}
for _, m in ipairs(sharedModules) do
    local src = "shared/lib/" .. m .. ".tl"
    local dst = "build/" .. m .. ".lua"
    os.execute("tl gen -o " .. dst .. " " .. src .. " 2>/dev/null")
end

-- Symlink internal/ for the threaded asset loader worker.
os.execute("cd build && ln -sf ../../../build/tecs2d/assets/internal internal")

-- Symlink assets into build/ if not already present.
-- os.execute returns a number in LuaJIT (0 = success), not a boolean.
local function dirExists(path: string): boolean
    return (os.execute("test -d '" .. path .. "'") as integer) == 0
end

if not dirExists("build/assets") then
    if dirExists("assets") then
        os.execute("cd build && ln -sf ../assets assets")
    else
        os.execute("cd build && ln -sf ../shared/assets assets")
    end
end
