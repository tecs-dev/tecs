-- Build and run the game, passing through any command line arguments
local args = {...}
local argstr = table.concat(args, " ")
local love_cmd = os.getenv("LOVE") or "love"

-- Build: compile example src/, run pre/post scripts
os.execute("tl run shared/scripts/build_tecs.tl")
os.execute("tl gen --root src --output-dir build " .. (io.popen("find src -name '*.tl'"):read("*a"):gsub("\n", " ")))
os.execute("tl run shared/scripts/link_tecs.tl")

if argstr == "--build-only" then
    return
end

local cmd = love_cmd .. " build " .. argstr
os.execute(cmd)
